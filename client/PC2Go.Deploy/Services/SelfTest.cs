using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using PC2Go.Deploy.Models;

namespace PC2Go.Deploy.Services
{
    /// <summary>
    /// -SelfTest -Out file [-Catalog apps.json]: one JSON report of what the client would do,
    /// produced by the real code paths with no window. tests\Test-Client.ps1 reads it back and
    /// pins the contract: the worker bytes, the stub, the queue entry, the status parse, the
    /// catalog rules. A pin on a probe is worth exactly what the probe shares with the product,
    /// which is why nothing here is reimplemented - every value is the product's own call.
    /// </summary>
    public static class SelfTest
    {
        public static void Run(Options o)
        {
            var rep = new Dictionary<string, object>();
            rep["build"] = App.BuildTag;
            rep["exe"] = App.ExePath();

            // the worker exactly as Start-Worker would write it, and its hash
            var body = WorkerHost.WorkerSource().Replace("\r\n", "\n").Replace("\n", "\r\n");
            if (!body.EndsWith("\r\n")) body += "\r\n";
            var bytes = new UTF8Encoding(true).GetPreamble().Concat(Encoding.UTF8.GetBytes(body)).ToArray();
            rep["workerBytes"] = bytes.Length;
            rep["workerSha256"] = WorkerHost.Sha256Hex(bytes);
            rep["workerFirstLine"] = body.Split('\n')[0].TrimEnd('\r');
            rep["workerPlaceholdersLeft"] = new[] { "#__NVAPISOURCE__", "#__SHAREDTABLES__", "#__INSTALLERFAMILY__" }.Where(p => body.Contains(p)).ToArray();

            // the reader (the Uninstall tab's reads), as embedded
            var readerText = Reader.Source();
            rep["readerBytes"] = Encoding.UTF8.GetByteCount(readerText);
            rep["readerSha256"] = WorkerHost.Sha256Hex(Encoding.UTF8.GetBytes(readerText));
            rep["readerOps"] = new[] { "installed", "store", "leftovers", "winget", "winupdate", "accounts", "migrateitems", "migratedefs", "manifest", "foldersize", "shares", "netscan", "hostshares", "tweakdefs", "tweakprobe", "firewall", "fwmap", "startupapps", "disks", "diagremedies", "gameprobe" }.Where(op => readerText.Contains("'" + op + "' {")).ToArray();

            var cache = Path.Combine(Path.GetTempPath(), "pc2go-selftest");
            var host = new WorkerHost(cache);
            rep["stub"] = WorkerHost.BuildStub(host.WorkerPath, host.StatusPath, host.QueuePath, host.CancelPath, host.SkipPath, new string('A', 64), 4242);

            // a queue entry for a synthetic row, built by the same code the batch uses
            var item = new AppItem
            {
                Id = "self test", Name = "Self Test", Url = "https://example.invalid/files/Setup.exe",
                Sha256 = new string('B', 64), SilentArgs = "/S", VerifyPaths = new[] { "%ProgramFiles%\\Self Test\\app.exe" },
                Entry = "", InstallTimeoutSec = 0, AllowUi = false, SilentSource = "detected", InstallerFamily = "NSIS",
                PostInstall = new object[] { new Dictionary<string, object> { { "type", "copy" }, { "name", "licence" }, { "from", "x\\y.key" }, { "dest", "C:\\Program Files\\Self Test\\" }, { "stopOnError", false } } }
            };
            rep["safeId"] = Catalog.SafeId(item.Id);
            rep["queueEntry"] = BatchPlan.InstallEntry(item, Path.Combine(cache, "files", Catalog.SafeId(item.Id), "Setup.exe"), "S-1-5-21-1-2-3-1001", new List<Dictionary<string, object>> { BatchPlan.StepFor((Dictionary<string, object>)item.PostInstall[0], Path.Combine(cache, "files", Catalog.SafeId(item.Id), "y.key")) });

            // status lines, parsed by the same reader the timer uses
            var st = WorkerHost.Parse("{\"id\":\"self test\",\"state\":\"Installing\",\"detail\":\"running Setup.exe /S\",\"dirty\":false,\"pct\":42,\"bytes\":10,\"total\":100,\"rate\":5,\"elapsed\":7}");
            rep["statusParse"] = new Dictionary<string, object> { { "id", st.Id }, { "state", st.State }, { "detail", st.Detail }, { "dirty", st.Dirty }, { "pct", st.Pct }, { "bytes", st.Bytes }, { "total", st.Total }, { "rate", st.Rate }, { "elapsed", st.Elapsed } };
            var st2 = WorkerHost.Parse("{\"id\":\"_batch\",\"state\":\"Complete\",\"detail\":\"\",\"dirty\":false}");
            rep["statusBatch"] = new Dictionary<string, object> { { "id", st2.Id }, { "state", st2.State }, { "pct", st2.Pct } };

            // the words a row gets from a status record, and how they are shortened once settled
            var words = new List<object>();
            foreach (var probe in new[] { "Installed", "Failed", "Skipped", "Installing", "Cleaned" })
            {
                var s = new WorkerStatus { Id = "x", State = probe, Detail = (probe == "Installing") ? "running" : "because of a reason - and more" };
                var r = BatchPlan.RowWords(s, false, "Install");
                words.Add(new Dictionary<string, object> { { "state", probe }, { "text", r.Text }, { "kind", r.Kind }, { "ring", r.Ring }, { "short", BatchPlan.ShortStatus(r.Text, r.Kind) } });
            }
            rep["rowWords"] = words;
            rep["cleanedDirty"] = BatchPlan.RowWords(new WorkerStatus { Id = "x", State = "Cleaned", Detail = "3 folders removed" }, true, "Install").Text;

            // the Firewall row projection, the queue entries and the batch summary, on synthetic rows
            var fwRows = new[]
            {
                new FwRow { Id = "fw-a", Name = "Blocked App", Publisher = "Vendor A", Root = @"C:\Program Files\Blocked App", On = 3, Off = 1, IconSources = new[] { @"C:\Program Files\Blocked App\a.exe" } },
                new FwRow { Id = "fw-b", Name = "Off App", Publisher = "Vendor B", Root = @"C:\Program Files\Off App", On = 0, Off = 2 },
                new FwRow { Id = "fw-c", Name = "Open App", Publisher = "Vendor C", Root = @"C:\Program Files\Open App", On = 0, Off = 0 },
                new FwRow { Id = "fwx-d", Name = "Adobe", Publisher = "", Root = @"C:\Program Files (x86)\Common Files\Adobe", On = 4, Off = 0, Stray = true, RuleNames = new[] { "Block-1", "Block-2", "Block-3", "Block-4" } },
            }.Select(FirewallList.Row).ToList();
            rep["fwRows"] = fwRows.Select(i => new Dictionary<string, object> {
                { "id", i.Id }, { "size", i.Size }, { "badgeBg", i.BadgeBg }, { "iconBg", i.IconBg }, { "category", i.Category }, { "source", i.Source },
                { "isSilent", i.IsSilent }, { "on", i.DetectPath }, { "off", i.OrigState }, { "regKey", i.RegKey ?? "" }, { "publisher", i.Publisher }, { "version", i.Version },
                { "hasRules", FirewallList.HasRules(i) }, { "tokens", i.CleanTokens.Length } }).ToArray();
            rep["fwEntries"] = new[] { FirewallList.Entry("fwblock", fwRows[2], App.BuildTag), FirewallList.Entry("fwunblock", fwRows[0], App.BuildTag), FirewallList.Entry("fwunblock", fwRows[3], App.BuildTag) };
            var fwPending = new[]
            {
                new AppItem { Status = "Applied", StatusDetail = "5 rule(s) added, 2 already blocked, 1 switched back on. Running copies keep their current connections until restarted." },
                new AppItem { Status = "Skipped", StatusDetail = "0 rule(s) added, 3 already blocked - nothing to do, this app was already fully blocked" },
                new AppItem { Status = "Applied", StatusDetail = "4 rule(s) removed (1 of them created by something other than this tool). Internet access is restored immediately." },
                new AppItem { Status = "Skipped", StatusDetail = "no block rules pointed at that folder" },
            };
            rep["fwSummary"] = new[] { FirewallList.BatchSummary(fwPending, "fallback"), FirewallList.BatchSummary(new[] { new AppItem { Status = "Failed", StatusDetail = "refused: C:\\ is a system or shared root" } }, "1 completed, 0 failed") };
            var fwMap = FirewallList.ParseMap("{\"rules\":[{\"Path\":\"C:\\\\Program Files\\\\Blocked App\\\\a.exe\",\"Name\":\"Block-1\",\"Display\":\"x\",\"Group\":\"Application Block\",\"Enabled\":true}," +
                                              "{\"Path\":\"c:\\\\program files\\\\blocked app\\\\sub\\\\b.exe\",\"Name\":\"Other-1\",\"Display\":\"y\",\"Group\":\"\",\"Enabled\":false}," +
                                              "{\"Path\":\"c:\\\\program files (x86)\\\\common files\\\\adobe\\\\c.exe\",\"Name\":\"Block-3\",\"Display\":\"z\",\"Group\":\"Legacy\",\"Enabled\":true}]}");
            rep["fwForeign"] = new[] { FirewallList.ForeignRuleCount(fwMap, new[] { fwRows[0] }), FirewallList.ForeignRuleCount(fwMap, new[] { fwRows[3] }), FirewallList.ForeignRuleCount(fwMap, new[] { fwRows[2] }) };
            int fwExes;
            rep["fwDetail"] = FirewallList.BlockedDetail(fwMap, @"C:\Program Files\Blocked App", out fwExes);

            // the batch order and the dependency check, on synthetic rows
            var cat = new List<AppItem>
            {
                new AppItem { Id = "autocad-2027", Name = "AutoCAD", SizeBytes = 4L << 30 },
                new AppItem { Id = "3ds-max", Name = "3ds Max", SizeBytes = 9L << 30 },
                new AppItem { Id = "revit", Name = "Revit", SizeBytes = 14L << 30 },
                new AppItem { Id = "acrobat", Name = "Acrobat", SizeBytes = 0 },
                new AppItem { Id = "plugin", Name = "Plugin", SizeBytes = 50L << 20, Requires = new[] { "3ds-max" } },
                new AppItem { Id = "office", Name = "Office", SizeBytes = 7L << 20 },
                new AppItem { Id = "electrical", Name = "Electrical", SizeBytes = 6L << 30, Requires = new[] { "autocad" } },
            };
            rep["batchOrder"] = BatchPlan.Order(new[] { cat[2], cat[3], cat[1], cat[4], cat[5] }, cat).Select(i => i.Id).ToArray();

            // the overall bar during the execution phase: every row is one share - settled rows have
            // all of it, a row the worker reports a figure for has that fraction, a row that is
            // running without a figure has half, a queued row has none. There is no sweep.
            Func<string, string, double, AppItem> row = (st, vis, pct) => new AppItem { Status = st, ProgressVis = vis, Progress = pct };
            Func<BatchPlan.Overall, string> ob = o => (o.Indeterminate ? "sweep" : Math.Round(o.Value, 1).ToString(System.Globalization.CultureInfo.InvariantCulture)) + "|" + o.Text;
            rep["overallBar"] = new[]
            {
                ob(BatchPlan.OverallFor(new[] { row("Queued", "Collapsed", 0), row("Applying", "Collapsed", 0), row("Queued", "Collapsed", 0), row("Queued", "Collapsed", 0) })),
                ob(BatchPlan.OverallFor(new[] { row("Running", "Collapsed", 0) })),
                ob(BatchPlan.OverallFor(new[] { row("Applied", "Collapsed", 0), row("Failed: x", "Collapsed", 0), row("Queued", "Collapsed", 0), row("Queued", "Collapsed", 0) })),
                ob(BatchPlan.OverallFor(new[] { row("Cleaned", "Collapsed", 0), row("Copying", "Visible", 50), row("Queued", "Collapsed", 0), row("Queued", "Collapsed", 0) })),
                ob(BatchPlan.OverallFor(new[] { row("Applied", "Collapsed", 0), row("Reverted", "Collapsed", 0), row("Skipped", "Collapsed", 0), row("Uninstalled", "Collapsed", 0) })),
                ob(BatchPlan.OverallFor(new AppItem[0])),
            };
            // the row the strip scrolls to keep in view: the first neither settled nor still queued
            Func<string, string, AppItem> nrow = (id, st) => new AppItem { Id = id, Status = st };
            Func<AppItem, string> an = a => a == null ? "(none)" : a.Id;
            rep["activeRow"] = new[]
            {
                an(BatchPlan.ActiveRow(new[] { nrow("a", "Applied"), nrow("b", "Applying"), nrow("c", "Queued") })),
                an(BatchPlan.ActiveRow(new[] { nrow("a", "Applied"), nrow("b", "Failed: x"), nrow("c", "Queued"), nrow("d", "Queued") })),
                an(BatchPlan.ActiveRow(new[] { nrow("a", "Queued"), nrow("b", "Queued") })),
                an(BatchPlan.ActiveRow(new[] { nrow("a", "Installed"), nrow("b", "Skipped") })),
                an(BatchPlan.ActiveRow(new[] { nrow("a", "Applied"), nrow("b", "Downloading 40%"), nrow("c", "Running") })),
            };
            var installed = cat.ToDictionary(c => c.Id, c => false, StringComparer.Ordinal);
            List<KeyValuePair<AppItem, string>> unknownDeps;
            var missingDeps = BatchPlan.MissingBases(new[] { cat[4], cat[6] }, installed, out unknownDeps);
            rep["depMissing"] = missingDeps.Select(m => m.Key.Id + "->" + m.Value).ToArray();
            rep["depUnknown"] = unknownDeps.Select(m => m.Key.Id + "->" + m.Value).ToArray();
            rep["depSatisfied"] = BatchPlan.MissingBases(new[] { cat[4], cat[1] }, installed, out unknownDeps).Count;

            // the cleanup summary's figure, the Startup row and its worker entry, and the fix table the Toolbox draws
            rep["reclaimed"] = Optimize.ReclaimedBytes(new[]
            {
                new AppItem { Status = "Applied", StatusDetail = "12 temp item(s) removed - 1.5 GB reclaimed" },
                new AppItem { Status = "Applied", StatusDetail = "recycle bin emptied on all drives (3 item(s)) - 300 MB reclaimed" },
                new AppItem { Status = "Applied", StatusDetail = "4 dump(s) and report(s) removed - under 1 MB reclaimed" },
                new AppItem { Status = "Applied", StatusDetail = "indexer on classic scope, paused on battery and yielding under load" },
            });
            var su = Optimize.StartupRow(new Optimize.StartupEntry { Name = "Discord", Command = "C:\\Users\\x\\AppData\\Local\\Discord\\Update.exe --processStart Discord.exe", Location = "HKCU\\Run", Enabled = true, Exe = "C:\\Users\\x\\AppData\\Local\\Discord\\Update.exe" });
            var suOff = Optimize.StartupRow(new Optimize.StartupEntry { Name = "OneDrive Setup.lnk", Command = "C:\\Users\\x\\Start Menu\\Programs\\Startup\\OneDrive Setup.lnk", Location = "StartupFolder", Enabled = false });
            rep["startupRows"] = new[] { su, suOff }.Select(i => new Dictionary<string, object> { { "id", i.Id }, { "category", i.Category }, { "isSilent", i.IsSilent }, { "size", i.Size }, { "iconText", i.IconText }, { "publisher", i.Publisher }, { "exe", i.IconSources.Length > 0 ? i.IconSources[0] : "" }, { "glyphVis", i.GlyphVis } }).ToArray();
            rep["startupEntries"] = new[] { Optimize.StartupEntryFor(su, false, "S-1-5-21-1-2-3-1001"), Optimize.StartupEntryFor(suOff, true, "S-1-5-21-1-2-3-1001") };
            // the icon cache key: the id AND the URL, so one server's logo (or miss) never stands in for another's
            rep["iconCacheKeys"] = new[] { IconPump.CacheName("winrar", "https://apps.pc2go.ca/icons/winrar.png"), IconPump.CacheName("winrar", "http://127.0.0.1:18800/icons/winrar.png"), IconPump.CacheName("winrar", " HTTPS://apps.pc2go.ca/icons/winrar.png ") };
            rep["fixIds"] = Toolbox.FixDefs.Select(f => f.Id).ToArray();

            // the Gaming sub-tab: the probe's sentence and the before/after gate (Format-/Compare-GamingProbe, word for word), the CAUTION costs table, the probe parse
            var pb = new Optimize.GameProbe { TimerP50 = 1.94, PreP50 = 0.02, PreP99 = 0.612, PreMax = 2.31, Dpc = 0.4, Isr = 0.1 };
            var pa = new Optimize.GameProbe { TimerP50 = 1.02, PreP50 = 0.01, PreP99 = 0.210, PreMax = 0.98, Dpc = 0.2, Isr = 0.1 };
            var pn = new Optimize.GameProbe { TimerP50 = 1.94, PreP50 = 0.02, PreP99 = 0.700, PreMax = 2.40, Dpc = -1, Isr = -1 };
            rep["gameFormat"] = new[] { Optimize.FormatProbe(pb), Optimize.FormatProbe(pn) };
            rep["gameCompare"] = new[] { Optimize.CompareProbe(pb, pa), Optimize.CompareProbe(pa, pb), Optimize.CompareProbe(pb, pn) }.Select(kv => kv.Key + "||" + kv.Value).ToArray();
            rep["gamingCosts"] = Optimize.GamingCosts.Keys.OrderBy(k => k, StringComparer.Ordinal).ToArray();
            // the probe explained: the thresholds a player feels, the narration turned into card states, the report's first line
            Func<string, Optimize.GameProbe, string> ev = (k, pr) => { var c = GameCards.Evaluate(k, pr); return c.Level + "|" + c.Verdict + "|" + c.Value + "|" + (c.Advice.Length > 0); };
            var smooth = new Optimize.GameProbe { TimerP50 = 1.0, PreP99 = 0.10, PreMax = 0.5, Dpc = 0.3, Isr = 0.1 };
            var felt = new Optimize.GameProbe { TimerP50 = 15.6, PreP99 = 0.60, PreMax = 3.0, Dpc = 2.0, Isr = 0.5 };
            var bad = new Optimize.GameProbe { TimerP50 = 15.6, PreP99 = 1.50, PreMax = 9.0, Dpc = 6.0, Isr = 1.0 };
            var unread = new Optimize.GameProbe { TimerP50 = 1.0, PreP99 = 0.10, PreMax = 0.5, Dpc = -1, Isr = -1 };
            rep["gameCards"] = new Dictionary<string, object>
            {
                { "stutter", new[] { ev("stutter", smooth), ev("stutter", felt), ev("stutter", bad) } },
                { "timer", new[] { ev("timer", smooth), ev("timer", felt) } },
                { "load", new[] { ev("load", smooth), ev("load", felt), ev("load", bad), ev("load", unread) } },
            };
            var cards = GameCards.Skeleton();
            GameCards.Begin(cards);
            var states = new List<string> { string.Join(",", cards.Select(c => c.Key + ":" + c.State)) };
            foreach (var line in new[] { "measuring... warming up", "measuring... preemption jitter round 2/3", "measuring... DPC load 1/3" })
            {
                GameCards.ApplyProgress(cards, line);
                states.Add(string.Join(",", cards.Select(c => c.Key + ":" + c.State + (c.State == "reading" ? "(" + c.Progress + ")" : ""))));
            }
            GameCards.Fill(cards, felt, false);
            states.Add(string.Join(",", cards.Select(c => c.Key + ":" + c.State + ":" + c.Value)));
            GameCards.Fill(cards, smooth, true);
            states.Add(string.Join(",", cards.Select(c => c.Key + ":" + c.Value + " " + c.After + ":" + c.Level)));
            rep["gameCardStates"] = states.ToArray();
            var rpt = GameCards.ReportText("PROBE", new DateTime(2026, 9, 9, 15, 30, 0), felt, smooth, Optimize.CompareProbe(felt, smooth));
            var rptLines = rpt.Replace("\r\n", "\n").Split('\n');
            rep["gameReport"] = new[] { rptLines[0], rptLines.Count(l => l.StartsWith("== ")).ToString(), rptLines.FirstOrDefault(l => l.StartsWith("VERDICT ")) ?? "" };
            var gp = Optimize.ParseGameProbe("{\"TimerP50\":1.9,\"PreP50\":0.0,\"PreP99\":0.25,\"PreMax\":1.5,\"Dpc\":0.3,\"Isr\":0.1,\"When\":\"2026-09-09T10:00:00\"}");
            rep["gameProbeParse"] = gp == null ? "" : gp.TimerP50.ToString(System.Globalization.CultureInfo.InvariantCulture) + "|" + gp.PreP99.ToString(System.Globalization.CultureInfo.InvariantCulture) + "|" + gp.PreMax.ToString(System.Globalization.CultureInfo.InvariantCulture) + "|" + gp.Dpc.ToString(System.Globalization.CultureInfo.InvariantCulture) + "|" + gp.When;

            // the Disk Management plan on four layouts, the worker entry, and the diagnosis report parse
            Func<long, long, string, string, PartInfo> part = (off, size, kind, letter) => new PartInfo { Number = 1, Offset = off, Size = size, Kind = kind, Letter = letter, MinSize = kind == "volume" ? size / 2 : 0 };
            const long G = 1L << 30, M = 1L << 20;
            var gapDisk = new DiskInfo { Number = 0, Size = 200 * G, Partitions = { part(1 * M, 100 * M, "system", ""), part(101 * M, 120 * G, "volume", "C") } };
            gapDisk.Partitions[1].GapAfter = 200 * G - (101 * M + 120 * G);
            var recDisk = new DiskInfo { Number = 0, Size = 200 * G, IsBoot = true, Partitions = { part(1 * M, 100 * M, "system", ""), part(101 * M, 120 * G, "volume", "C"), part(101 * M + 120 * G, 800 * M, "recovery", "") } };
            recDisk.Partitions[2].Number = 3; recDisk.Partitions[2].GapAfter = 200 * G - (101 * M + 120 * G + 800 * M);
            var dataDisk = new DiskInfo { Number = 1, Size = 200 * G, Partitions = { part(1 * M, 100 * G, "volume", "C"), part(1 * M + 100 * G, 50 * G, "volume", "D") } };
            dataDisk.Partitions[1].Number = 2; dataDisk.Partitions[1].GapAfter = 200 * G - (1 * M + 150 * G);
            var dynDisk = new DiskInfo { Number = 2, Size = 200 * G, IsDynamic = true, Partitions = { part(1 * M, 100 * G, "volume", "E") } };
            dynDisk.Partitions[0].GapAfter = 99 * G;
            // a 1 MB alignment gap, then another partition: slack, not free space - the partition behind is what Extend names
            var slackDisk = new DiskInfo { Number = 3, Size = 200 * G, Partitions = { part(1 * M, 150 * G, "volume", "E"), part(2 * M + 150 * G, 15 * G, "other", "") } };
            slackDisk.Partitions[0].GapAfter = 1 * M; slackDisk.Partitions[1].Number = 2;
            var plans = new[] { DiskTools.Extend(gapDisk, gapDisk.Partitions[1]), DiskTools.Extend(recDisk, recDisk.Partitions[1]), DiskTools.Extend(dataDisk, dataDisk.Partitions[0]), DiskTools.Extend(dynDisk, dynDisk.Partitions[0]), DiskTools.Extend(dataDisk, dataDisk.Partitions[1]), DiskTools.Extend(slackDisk, slackDisk.Partitions[0]) };
            rep["extendPlans"] = plans.Select(p => new Dictionary<string, object> { { "kind", p.Kind }, { "bytes", p.Bytes }, { "reason", p.Reason }, { "blocker", p.Blocker != null ? p.Blocker.Number : 0 } }).ToArray();
            rep["shrinkRoom"] = DiskTools.ShrinkRoom(gapDisk.Partitions[1]);
            rep["diskEntry"] = DiskTools.Entry("diskextendmove", recDisk, recDisk.Partitions[1], 0);
            var report = "PC2Go slow-PC triage   2026-09-05 01:10   PROBE\n\nVERDICT L0: OK\nVERDICT L1: chrome has used 900 CPU-seconds\nVERDICT L2: OK\nVERDICT L3: OK\nVERDICT L4: OK\nVERDICT L5: 2 startup items worth reviewing: McAfee, Norton\nVERDICT L6: OK\n\n" +
                         "== L0  hardware ==\n   disk    SSD  NVMe  954 GB\n== L1  what is running ==\n   chrome  900 s\n== L2  security software ==\n== L3  memory ==\n== L4  background work ==\n== L5  startup and persistence ==\n   run     McAfee\n   run     Norton\n== L6  faults and throttling ==\n";
            var diag = Diagnosis.Parse(report);
            rep["diagLayers"] = diag.Select(l => new Dictionary<string, object> { { "key", l.Key }, { "name", l.Name }, { "verdict", l.Verdict }, { "ok", l.Ok }, { "lines", l.Lines } }).ToArray();
            rep["diagHeader"] = Diagnosis.Header(report);
            // the screen before a run, and a run reporting layer by layer
            var live = Diagnosis.Skeleton();
            rep["diagSkeleton"] = live.Select(l => l.State + ":" + l.VerdictText).ToArray();
            live[0].State = "reading";
            var applied = new[] { Diagnosis.ApplyVerdict(live, "Checking: VERDICT L0: OK"), Diagnosis.ApplyVerdict(live, "Checking: VERDICT L1: chrome has used 900 CPU-seconds"), Diagnosis.ApplyVerdict(live, "Applying") };
            rep["diagLive"] = new Dictionary<string, object> { { "applied", applied }, { "states", live.Select(l => l.State).ToArray() }, { "l1", live[1].VerdictText }, { "bars", live.Select(l => l.Bar).Distinct().Count() } };
            // the remedies: a small table of the script's shape, the report explained against it
            Diagnosis.Remedies = new List<Remedy>
            {
                new Remedy { Layer = "L1", Match = @"^(\S+) has used \d+ CPU-seconds", Kind = "uninstall", Target = "1", Label = "Find it in Uninstall", Note = "n1" },
                new Remedy { Layer = "L5", Match = @"worth reviewing: (.+)", Kind = "startup", Target = "1", Label = "Review startup entries", Note = "n5" },
                new Remedy { Layer = "L0", Match = "spinning disk", Kind = "none", Target = "", Label = "", Note = "hardware" },
            };
            var explained = Diagnosis.Parse(report);
            rep["diagFindings"] = explained.Select(l => new Dictionary<string, object> { { "key", l.Key }, { "verdictVis", l.VerdictVis },
                { "findings", l.Findings.Select(f => f.Kind + "|" + f.Label + "|" + string.Join(",", f.Names) + "|" + f.HasButton).ToArray() } }).ToArray();
            var odd = new DiagLayer { Key = "L3", Name = "Memory", Verdict = "a sentence no remedy row knows; the machine is paging", State = "finding" };
            Diagnosis.Explain(odd, Diagnosis.Remedies);
            rep["diagUnmatched"] = odd.Findings.Select(f => f.Kind + "|" + f.Label + "|" + f.HasButton + "|" + (f.Note == Diagnosis.NoRemedyNote)).ToArray();
            // the "What to do" card: the report's findings with buttons as numbered steps; a clean report gets the general approach; a run still reading gets no card
            var plan = Diagnosis.Plan(explained, true);
            rep["diagPlan"] = new Dictionary<string, object> { { "visible", plan.Visible }, { "steps", plan.Steps.Select(s => s.Step + ":" + s.Kind + ":" + s.Label).ToArray() }, { "notes", plan.Notes.Count }, { "summary", plan.Summary } };
            var cleanReport = Diagnosis.Parse("PC2Go slow-PC triage   2026-09-05 01:10   PROBE\n\nVERDICT L0: OK\nVERDICT L1: OK\nVERDICT L2: OK\nVERDICT L3: OK\nVERDICT L4: OK\nVERDICT L5: OK\nVERDICT L6: OK\n");
            var planClean = Diagnosis.Plan(cleanReport, true);
            rep["diagPlanClean"] = new Dictionary<string, object> { { "visible", planClean.Visible }, { "steps", planClean.Steps.Select(s => s.Step + ":" + s.Kind + ":" + s.Target).ToArray() }, { "notes", planClean.Notes.Count }, { "summary", planClean.Summary } };
            var noteOnly = new List<DiagLayer> { new DiagLayer { Key = "L0", Name = "Hardware", Verdict = "spinning disk - software cleanup buys very little", State = "finding" } };
            Diagnosis.Explain(noteOnly[0], Diagnosis.Remedies);
            var planNotes = Diagnosis.Plan(noteOnly, true);
            rep["diagPlanNotes"] = new Dictionary<string, object> { { "steps", planNotes.Steps.Count }, { "notes", planNotes.Notes.Count }, { "summary", planNotes.Summary } };
            rep["diagPlanRunning"] = Diagnosis.Plan(live, true).Visible;   // L2 onwards still pending in the live run above
            Diagnosis.Remedies = new List<Remedy>();
            rep["diagReportPath"] = Diagnosis.ReportPathFrom("found at L1 - chrome has used 900 CPU-seconds   (report: C:\\Users\\x\\AppData\\Local\\PC2GoDeploy\\slowpc-20260905-011000.txt)");

            rep["formatSize"] = new[] { Format.Size(0), Format.Size(512 * 1024), Format.Size(5L * 1024 * 1024), Format.Size(3L * 1024 * 1024 * 1024) };
            rep["formatEta"] = new[] { Format.Eta(1000, 100), Format.Eta(100000, 100), Format.Eta(0, 100) };
            rep["diskVerdict"] = new[] { BatchPlan.DiskVerdict(0, 0, 0), BatchPlan.DiskVerdict(10, 100, 20), BatchPlan.DiskVerdict(3L << 30, 100L << 30, 2L << 30), BatchPlan.DiskVerdict(50L << 30, 100L << 30, 1L << 30) };

            if (!string.IsNullOrEmpty(o.SelfTestCatalog))
            {
                var load = Catalog.Parse(File.ReadAllText(o.SelfTestCatalog, Encoding.UTF8));
                rep["catalogIds"] = load.Items.Select(i => i.Id).ToArray();
                rep["catalogCategories"] = load.Categories.ToArray();
                rep["catalogSkipped"] = load.Skipped.ToArray();
                rep["catalogRows"] = load.Items.Select(i => new Dictionary<string, object> {
                    { "id", i.Id }, { "name", i.Name }, { "category", i.Category }, { "size", i.Size }, { "fileName", i.FileName },
                    { "sha256", i.Sha256 }, { "iconText", i.IconText }, { "iconBg", i.IconBg }, { "detect", i.DetectPath ?? "" },
                    { "requires", i.Requires }, { "family", i.InstallerFamily }, { "postInstall", i.PostInstall.Length } }).ToArray();
            }

            File.WriteAllText(o.SelfTestOut ?? "selftest.json", Json.Serialize(rep), new UTF8Encoding(false));
        }
    }
}
