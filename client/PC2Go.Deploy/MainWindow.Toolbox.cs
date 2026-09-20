using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Data;
using System.Windows.Media;
using PC2Go.Deploy.Models;
using PC2Go.Deploy.Services;

namespace PC2Go.Deploy
{
    /// <summary>
    /// The Toolbox, three sub-tabs. Tools: repair actions on the left, shortcuts to the legacy
    /// Windows panels on the right - a fix is queued and run elevated with the rest of a batch,
    /// whereas a panel just opens. Diagnose: the slow-PC report as a screen of its own, seven layers
    /// in reading order, not a checkbox in the list. Disk Management: every disk as a bar, Shrink and
    /// Extend per volume, and the one job Disk Management refuses - extending past the recovery
    /// partition - as a single, explained action.
    /// </summary>
    public partial class MainWindow
    {
        private readonly ObservableCollection<AppItem> _fixItems = new ObservableCollection<AppItem>();
        private ListCollectionView _fixView;
        private bool _toolsLoaded;
        private string _toolsSubTab = "Tools";
        private AppItem _diagRow;                 // the slow-PC diagnosis, run from the Diagnose screen
        private string _diagReportPath = "", _diagStamp = "";   // where the last report is, and when it was made
        private List<DiagLayer> _diagLayers;      // the seven cards on the Diagnose screen, live while a run reports
        private bool _diagHooked, _diagRemediesLoaded;
        private List<DiskInfo> _disks = new List<DiskInfo>();
        private bool _diskLoaded, _diskLoading;
        private Action<long> _diskDialogOk;       // what the Shrink / Extend dialog does with the amount

        private void WireToolbox()
        {
            _fixView = (ListCollectionView)CollectionViewSource.GetDefaultView(_fixItems);
            _fixView.GroupDescriptions.Add(new PropertyGroupDescription("Category"));
            _fixView.Filter = FilterRow;
            ListFix.ItemsSource = _fixView;
            BtnRunFix.Click += (s, e) => OnRunFixClick();
            BtnAlCancel.Click += (s, e) => AutoLogonOverlay.Visibility = Visibility.Collapsed;
            TxtAlUser.TextChanged += (s, e) => HintAlUser.Visibility = TxtAlUser.Text.Length > 0 ? Visibility.Collapsed : Visibility.Visible;
            TxtAlPw.TextChanged += (s, e) => HintAlPw.Visibility = TxtAlPw.Text.Length > 0 ? Visibility.Collapsed : Visibility.Visible;
            BtnAlOk.Click += (s, e) => OnAutoLogonOk();
            BtnToolsSubTools.Click += (s, e) => SelectToolsTab("Tools");
            BtnToolsSubDiag.Click += (s, e) => SelectToolsTab("Diag");
            BtnToolsSubDisk.Click += (s, e) => SelectToolsTab("Disk");
            BtnDiskRescan.Click += (s, e) => { if (!TestBatchBusy()) { _diskLoaded = false; var _ = LoadDisksAsync(); } };
            BtnDiskCancel.Click += (s, e) => DiskOverlay.Visibility = Visibility.Collapsed;
            BtnDiskOk.Click += (s, e) => OnDiskDialogOk();
            BtnDiagRun.Click += (s, e) => OnRunFixClick();
            // a finding's remedy button lives inside the card template: its Click bubbles to the list - the same for the plan's steps
            ListDiag.AddHandler(ButtonBase.ClickEvent, new RoutedEventHandler(OnDiagRemedyClick));
            ListPlan.AddHandler(ButtonBase.ClickEvent, new RoutedEventHandler(OnDiagRemedyClick));
        }

        private void OnToolsTabShown()
        {
            SelectToolsTab(_toolsSubTab);
            if (_toolsLoaded) return;
            _toolsLoaded = true;
            LoadToolbox();
        }

        private void SelectToolsTab(string which)
        {
            _toolsSubTab = which;
            BtnToolsSubTools.Style = (Style)FindResource(which == "Tools" ? "TabActive" : "TabIdle");
            BtnToolsSubDiag.Style = (Style)FindResource(which == "Diag" ? "TabActive" : "TabIdle");
            BtnToolsSubDisk.Style = (Style)FindResource(which == "Disk" ? "TabActive" : "TabIdle");
            PanelToolsMain.Visibility = which == "Tools" ? Visibility.Visible : Visibility.Collapsed;
            PanelDiagnose.Visibility = which == "Diag" ? Visibility.Visible : Visibility.Collapsed;
            PanelDisk.Visibility = which == "Disk" ? Visibility.Visible : Visibility.Collapsed;
            BtnDiskRescan.Visibility = which == "Disk" ? Visibility.Visible : Visibility.Collapsed;
            var onTab = _tab == "Toolbox";
            // one button per job: Run Selected for the fixes; the Diagnose screen has Run Diagnosis on
            // its header card, and the disks have Shrink and Extend per volume - a second Run
            // Diagnosis on the bottom bar was the same button twice on one screen
            BtnRunFix.Visibility = (which == "Tools" && onTab) ? Visibility.Visible : Visibility.Collapsed;
            BtnRunFix.Content = "Run Selected";
            TxtToolsHint.Text = which == "Disk" ? (_diskLoading ? "reading the disks - each volume is asked how far it can shrink..." : DiskHint) : "";
            if (which == "Diag" && _diagLayers == null) ShowLastDiagnosis();
            if (which == "Disk" && !_diskLoaded && !_diskLoading) { var _ = LoadDisksAsync(); }
            UpdateDash();
        }

        /// <summary>Load-Toolbox: the fix rows from the table (the diagnosis has its own screen), and one tile per legacy panel with its real Windows icon pulled off-thread.</summary>
        private void LoadToolbox()
        {
            _fixItems.Clear();
            foreach (var d in Toolbox.FixDefs)
            {
                var item = FixRow(d);
                if (d.Group == "Diagnostics") { _diagRow = item; continue; }   // Diagnose sub-tab, not a checkbox
                item.PropertyChanged += (s, e) => { if (e.PropertyName == "IsSelected") UpdateDash(); };
                _fixItems.Add(item);
            }
            PanelGrid.Children.Clear();
            foreach (var p in Toolbox.PanelDefs)
            {
                var def = p;
                // the icon AND its name: fourteen icons alone were a guessing game (three shields, two
                // monitors), and a name that only lives in a tooltip is read by nobody in a hurry
                var b = new Button { Style = (Style)FindResource("IconTile"), ToolTip = def.Name, Width = 106, Height = 90 };
                // 32px is the icon's native size, so it renders crisp rather than resampled
                var img = new Image { Width = 32, Height = 32, Stretch = Stretch.Uniform, Margin = new Thickness(0, 0, 0, 7) };
                RenderOptions.SetBitmapScalingMode(img, BitmapScalingMode.HighQuality);
                var cap = new TextBlock { Text = def.Name, FontSize = 10.5, Foreground = Res("Muted"), TextAlignment = TextAlignment.Center, TextWrapping = TextWrapping.Wrap, MaxWidth = 94 };
                var tile = new StackPanel { HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
                tile.Children.Add(img); tile.Children.Add(cap);
                b.Content = tile;
                b.Click += (s, e) => StartLegacyPanel(def);
                PanelGrid.Children.Add(b);
                // the real Windows icon, pulled off-thread; the button appears immediately either way
                Task.Run(() =>
                {
                    var got = Toolbox.PanelIcon(def);
                    if (got != null) Dispatcher.BeginInvoke(new Action(() => img.Source = got));
                });
            }
            Log("Toolbox: " + Format.Count(_fixItems.Count, "fix", "fixes") + ", " + Format.Count(Toolbox.PanelDefs.Length, "legacy panel", "legacy panels") + ".");
            UpdateDash();   // the dash was computed before the rows existed and read "0 fixes"
        }

        private static AppItem FixRow(FixDef d)
        {
            return new AppItem
            {
                Id = "fix-" + d.Id, Name = d.Name, UnArgs = d.Id, Size = "", Publisher = d.Hint, Category = d.Group, IsSilent = true,
                IconBg = d.Group == "Remote Access" ? "#FFF59E0B" : "#FF2563EB", IconData = Catalog.IconMap["default"][0], RowOpacity = 1.0,
            };
        }

        /// <summary>Start-LegacyPanel: unelevated, fire-and-forget, no busy guard - a panel opens even mid-batch, by design.</summary>
        private void StartLegacyPanel(PanelDef p)
        {
            try
            {
                var psi = new ProcessStartInfo { FileName = p.Cmd, UseShellExecute = true };
                if (!string.IsNullOrEmpty(p.Args)) psi.Arguments = p.Args;
                Process.Start(psi);
                Log("Opened " + p.Name + ".");
            }
            catch (Exception ex)
            {
                Log("Could not open " + p.Name + ": " + ex.Message);
                ShowOverlay("Could not open " + p.Name, ex.Message);
            }
        }

        private string ToolsDashText()
        {
            if (_toolsSubTab == "Diag")
            {
                // the header card already names the report file; the dash says what it found and when
                if (_diagLayers == null) return "No diagnosis run yet";
                var reading = _diagLayers.FirstOrDefault(l => l.State == "reading");
                if (reading != null) return "Reading " + reading.Name.ToLowerInvariant() + "...";
                if (_diagReportPath.Length == 0) return "No diagnosis run yet";
                // the What-to-do card counts the findings; the dash keeps only when the report was made
                return _diagStamp.Length > 0 ? "Last run " + _diagStamp : "Last report on screen";
            }
            if (_toolsSubTab == "Disk") return Format.Count(_disks.Count, "disk", "disks") + ", " + Format.Count(_disks.Sum(d => d.Partitions.Count(p => p.Kind == "volume")), "volume", "volumes");
            var n = _fixItems.Count(i => i.IsSelected);
            // the group headers count the fixes; the dash is for the selection
            return n > 0 ? Format.Count(n, "fix", "fixes") + " selected" : "Tick the repairs to run";
        }

        // ------------------------------------------------------------------ the batch

        private void OnRunFixClick()
        {
            if (TestBatchBusy()) return;
            if (_toolsSubTab == "Diag")
            {
                if (_diagRow == null) { ShowOverlay("No diagnosis row", "The fix table has no Diagnostics entry."); return; }
                // the seven cards go grey and the first turns "reading" now; each turns as the worker reports it
                _diagLayers = Diagnosis.Skeleton();
                _diagLayers[0].State = "reading";
                ListDiag.ItemsSource = _diagLayers;
                CardPlan.Visibility = Visibility.Collapsed;   // the plan is for a finished report; it comes back with the file
                TxtDiagHead.Text = "Reading " + Environment.MachineName + " - seven layers in order, nothing is changed.";
                if (!_diagHooked)
                {
                    _diagHooked = true;
                    _diagRow.PropertyChanged += (s, e) =>
                    {
                        if (e.PropertyName != "StatusDetail" && e.PropertyName != "Status") return;
                        if (_diagLayers == null) return;
                        var text = string.IsNullOrEmpty(_diagRow.StatusDetail) ? _diagRow.Status : _diagRow.StatusDetail;
                        Diagnosis.ApplyVerdict(_diagLayers, text);
                    };
                }
                Log("Running the slow-PC diagnosis - seven layers, changes nothing.");
                StartFixBatch(new List<AppItem> { _diagRow }, null);
                return;
            }
            var sel = _fixItems.Where(i => i.IsSelected).ToList();
            if (sel.Count == 0) { ShowOverlay("Nothing selected", "Tick the repairs you want to run."); return; }
            // AutoLogon needs credentials, so it cannot ride along in a multi-select batch
            if (sel.Any(i => i.UnArgs == "autologon"))
            {
                if (sel.Count > 1)
                {
                    ShowOverlay("Run AutoLogon on its own", "AutoLogon needs an account and password, so run it by itself - untick the others.");
                    return;
                }
                TxtAlUser.Clear(); TxtAlPw.Clear();
                try { TxtAlUser.Text = Environment.UserName; } catch { }
                FadeIn(AutoLogonOverlay);
                return;
            }
            var longOnes = sel.Any(i => i.UnArgs == "sfc" || i.UnArgs == "wureset");
            var reboot = sel.Any(i => i.UnArgs == "netreset");
            var ssh = sel.Any(i => i.UnArgs == "openssh");
            var restart = sel.Any(i => i.UnArgs == "restart");
            var msg = Format.Count(sel.Count, "repair", "repairs") + " will run, one after another, under a single UAC prompt:\n\n" +
                      string.Join("\n", sel.Select(i => "  - " + i.Name));
            if (longOnes) msg += "\n\nSystem Corruption Scan and Windows Update Reset are slow - allow up to 30 minutes each. The window will look busy, not stuck.";
            if (reboot) msg += "\n\nNetwork Reset does not take effect until the machine restarts.";
            if (restart) msg += "\n\nRestart Now restarts this PC 60 seconds after it runs, with a message on screen. Unsaved work on it is lost; \"shutdown /a\" cancels it.";
            if (ssh) msg += "\n\nOpenSSH Server opens port 22 and gives remote shell access to this PC. Only enable it on a machine you control, and make sure the accounts on it have real passwords.";
            ShowConfirm("Run these repairs?", msg, "Continue", () => StartFixBatch(sel, null));
        }

        /// <summary>The AutoLogon dialog IS the confirmation - it bypasses the confirm sheet.</summary>
        private void OnAutoLogonOk()
        {
            var u = (TxtAlUser.Text ?? "").Trim();
            if (u.Length == 0) { ShowOverlay("No account", "Type the account that should sign in automatically."); return; }
            var pw = TxtAlPw.Text ?? "";
            AutoLogonOverlay.Visibility = Visibility.Collapsed;
            var row = _fixItems.Where(i => i.UnArgs == "autologon").ToList();
            StartFixBatch(row, new Dictionary<string, object> { { "alUser", u }, { "alPassword", pw } });
        }

        /// <summary>Start-FixBatch: one `fix` entry per row, AutoLogon's password DPAPI-protected before the worker exists.</summary>
        private void StartFixBatch(List<AppItem> sel, Dictionary<string, object> extra)
        {
            var entries = new List<Dictionary<string, object>>();
            try
            {
                foreach (var s in sel)
                {
                    var e = new Dictionary<string, object> { { "id", s.Id }, { "action", "fix" }, { "fix", s.UnArgs ?? "" } };
                    if (extra != null) foreach (var kv in extra) e[kv.Key] = kv.Value;
                    entries.Add(AccountList.Protect(e));
                }
            }
            catch (Exception ex) { ShowOverlay("Could not protect the password", "The password could not be encrypted for the elevated worker, so nothing was started.\n\n" + ex.Message); return; }
            BeginToolsBatch(sel, entries, "Running repairs...", "Toolbox batch: " + Format.Count(sel.Count, "fix", "fixes") + " - " + string.Join(", ", sel.Select(x => x.UnArgs)) + ".");
        }

        /// <summary>The disk actions ride the same Tools batch: one row, one entry, the same closing sheet.</summary>
        private void StartDiskBatch(string action, DiskInfo d, PartInfo p, long bytes, string label)
        {
            var row = new AppItem { Id = "disk-" + d.Number + "-" + p.Number, Name = label, Category = "Disk", IsSilent = true, IconBg = "#FF2563EB", IconData = Catalog.IconMap["default"][0], RowOpacity = 1.0 };
            BeginToolsBatch(new List<AppItem> { row }, new List<Dictionary<string, object>> { DiskTools.Entry(action, d, p, bytes) },
                            "Changing the disk layout...", "Disk batch: " + action + " on disk " + d.Number + " partition " + p.Number + " (" + p.Title + "), " + (bytes > 0 ? Format.Size(bytes) : "maximum") + ".");
        }

        private void BeginToolsBatch(List<AppItem> rows, List<Dictionary<string, object>> entries, string now, string logLine)
        {
            foreach (var s in rows) { SetStatus(s, "Queued", "neutral"); SetRing(s, "queued"); }
            _pending = rows.ToList();
            _batchTab = "Tools";
            _runStarted = DateTime.Now;
            _dlIndex = 0; _lastLogKey.Clear();
            _hadFailures = false; _cancelRequested = false; _awaitingScan = false;
            _deepClean = false; _forceMode = false;
            _worker.ResetForBatch();
            ShowBatchStrip();
            if (!_worker.Start()) { AbortBatch("the administrator prompt was declined, so nothing was run", "warn"); return; }
            foreach (var e in entries) _worker.Enqueue(e);
            _worker.Complete();
            _phase = "Install";
            BtnRunFix.IsEnabled = false;
            BtnDiagRun.IsEnabled = false;   // the header card's button, greyed for the run like the bar's
            BtnInstall.IsEnabled = false;
            TxtNow.Text = now;
            DotNow.Fill = Brush("#FF4C8DFF");
            TxtStatus.Text = now;
            Log(logLine);
            UpdateDash();
        }

        /// <summary>
        /// Finish-Batch's Tools part. The closing sheet carries each row's own sentence: the worker
        /// wrote the Slow PC verdict and the report path into the detail, and a bare "1 completed,
        /// 0 failed" would hide exactly what the technician ran the diagnosis for. A diagnosis run
        /// also lands on the Diagnose screen; a disk change re-reads the disks.
        /// </summary>
        private void OnBatchEndedTools(string summary, int fail, int cans)
        {
            BtnRunFix.IsEnabled = true;
            BtnDiagRun.IsEnabled = true;
            if (_batchTab != "Tools") return;
            TxtAlPw.Clear();
            var said = _pending.Select(p => p.Name + "\n" + (string.IsNullOrEmpty(p.StatusDetail) ? p.Status : p.StatusDetail)).ToList();
            ShowOverlay(fail > 0 ? "Finished - with a failure" : (cans > 0 ? "Finished - check the details" : "Finished"),
                        summary + "\n\n" + string.Join("\n\n", said));
            if (_diagRow != null && _pending.Contains(_diagRow))
            {
                var path = Diagnosis.ReportPathFrom(_diagRow.StatusDetail);
                if (path.Length > 0) ShowDiagnosis(path);
                else
                {
                    Log("The diagnosis wrote no report file - the row's detail is all there is: " + _diagRow.StatusDetail);
                    TxtDiagHead.Text = "The run ended without a report file: " + (string.IsNullOrEmpty(_diagRow.StatusDetail) ? _diagRow.Status : _diagRow.StatusDetail);
                    if (_diagLayers != null) foreach (var l in _diagLayers) if (l.State == "reading" || l.State == "pending") { l.Verdict = "not reported"; l.State = "finding"; }
                    RefreshDiagPlan();
                }
            }
            if (_pending.Any(p => (p.Id ?? "").StartsWith("disk-", StringComparison.Ordinal))) { _diskLoaded = false; var _ = LoadDisksAsync(); }
        }

        // ------------------------------------------------------------------ Diagnose

        /// <summary>
        /// First look at the screen: the seven cards, grey, with the machine's name and what the
        /// run does - or, if this machine was diagnosed before, that report with every card painted.
        /// </summary>
        private void ShowLastDiagnosis()
        {
            _diagLayers = Diagnosis.Skeleton();
            ListDiag.ItemsSource = _diagLayers;
            TxtDiagHead.Text = "Not run yet on " + Environment.MachineName + ". Run Diagnosis reads the seven layers below in order - what is slow is almost always in one of them - and changes nothing on the machine. About a minute.";
            try
            {
                var last = Directory.GetFiles(_cacheDir, "slowpc-*.txt").OrderByDescending(f => f).FirstOrDefault();
                if (last != null) ShowDiagnosis(last);
            }
            catch { }
            if (!_diagRemediesLoaded) { var _ = LoadDiagRemediesAsync(); }
        }

        /// <summary>The remedy table, from the script through the reader, once; the cards already on screen are explained again when it lands.</summary>
        private async Task LoadDiagRemediesAsync()
        {
            _diagRemediesLoaded = true;
            try
            {
                var json = await _reader.RunAsync("diagremedies", null, null, CancellationToken.None, 60);
                Diagnosis.Remedies = Diagnosis.ParseRemedies(json);
                if (_diagLayers != null) { Diagnosis.ExplainAll(_diagLayers); RefreshDiagPlan(); }
                Log("Diagnose: " + Format.Count(Diagnosis.Remedies.Count, "remedy row", "remedy rows") + " - one per sentence the diagnosis can say.");
            }
            catch (Exception ex)
            {
                _diagRemediesLoaded = false;   // try again next time the screen opens
                Log("Diagnose: the remedy table could not be read - " + ex.Message + ". Findings show without buttons.");
            }
        }

        /// <summary>
        /// A finding's button: run the tweak or fix through the worker when the remedy is a single
        /// reversible action, or open the tab with the rows ticked when a person has to choose.
        /// </summary>
        private async void OnDiagRemedyClick(object sender, RoutedEventArgs e)
        {
            var b = e.OriginalSource as Button;
            var f = b != null ? b.DataContext as DiagFinding : null;
            if (f == null) return;
            e.Handled = true;
            try
            {
                switch (f.Kind)
                {
                    case "tweak":
                    {
                        if (TestBatchBusy()) return;
                        await EnsureTweaksLoadedAsync();
                        var row = _tweakItems.FirstOrDefault(i => i.UnArgs == f.Target);
                        if (row == null) { ShowOverlay("Tweak not found", "The tweak table has no row '" + f.Target + "'."); return; }
                        SelectTab("Optimize"); SelectOptTab("Tweaks");
                        row.IsSelected = true;
                        Log("Diagnose -> running the tweak '" + row.Name + "' for: " + f.Text);
                        await StartTweaksAsync(new List<AppItem> { row });
                        return;
                    }
                    case "fix":
                    {
                        if (TestBatchBusy()) return;
                        var def = Toolbox.FixDefs.FirstOrDefault(d => d.Id == f.Target);
                        if (def == null) { ShowOverlay("Fix not found", "The fix table has no row '" + f.Target + "'."); return; }
                        var row = FixRow(def);
                        if (f.Target == "restart")
                        {
                            ShowConfirm("Restart this PC?", "It restarts 60 seconds after you continue, with a message on screen. Unsaved work on it is lost; \"shutdown /a\" from any prompt cancels it.\n\nRun the diagnosis again once it is back.",
                                        "Restart", () => { Log("Diagnose -> restart for: " + f.Text); StartFixBatch(new List<AppItem> { row }, null); });
                            return;
                        }
                        Log("Diagnose -> running the fix '" + def.Name + "' for: " + f.Text);
                        StartFixBatch(new List<AppItem> { row }, null);
                        return;
                    }
                    case "cleanup":
                        SelectTab("Optimize"); SelectOptTab("Clean");
                        await EnsureTweaksLoadedAsync();
                        OnPreClear();   // the default safe set, ticked
                        Log("Diagnose -> Cleanup, for: " + f.Text);
                        return;
                    case "tweaks":
                        // the general approach's step: the Tweaks sub-tab with its pre-ticked set, the technician presses Apply
                        SelectTab("Optimize"); SelectOptTab("Tweaks");
                        await EnsureTweaksLoadedAsync();
                        Log("Diagnose -> Tweaks, for: " + f.Text);
                        return;
                    case "startup":
                    {
                        SelectTab("Optimize"); SelectOptTab("Startup");
                        if (_startupLoadTask != null) await _startupLoadTask;
                        var names = f.Names ?? new string[0];
                        var ticked = 0;
                        _suspendDash = true;
                        try
                        {
                            foreach (var row in _startupItems)
                            {
                                var hit = row.IsSilent && names.Any(n => n.Length > 0 && (row.Name ?? "").IndexOf(n, StringComparison.OrdinalIgnoreCase) >= 0);
                                row.IsSelected = hit;
                                if (hit) ticked++;
                            }
                        }
                        finally { _suspendDash = false; }
                        UpdateDash();
                        Log("Diagnose -> Startup, " + Format.Count(ticked, "entry", "entries") + " ticked for: " + f.Text);
                        return;
                    }
                    case "uninstall":
                    {
                        // the first name that is not Defender: Defender stays, the other one goes
                        var name = (f.Names ?? new string[0]).FirstOrDefault(n => n.IndexOf("Defender", StringComparison.OrdinalIgnoreCase) < 0) ?? "";
                        SelectTab("Uninstall");
                        TxtSearch.Text = name;
                        Log("Diagnose -> Uninstall filtered to '" + name + "' for: " + f.Text);
                        return;
                    }
                    case "backup":
                        SelectTab("Data Backup");
                        Log("Diagnose -> Data Backup, for: " + f.Text);
                        return;
                }
            }
            catch (Exception ex) { Log("Diagnose: the remedy could not be started - " + ex.Message); }
        }

        private void ShowDiagnosis(string path)
        {
            try
            {
                var text = File.ReadAllText(path);
                if (_diagLayers == null) { _diagLayers = Diagnosis.Skeleton(); ListDiag.ItemsSource = _diagLayers; }
                Diagnosis.Fill(_diagLayers, text);
                _diagReportPath = path;
                _diagStamp = Regex.Match(Diagnosis.Header(text), @"\d{4}-\d{2}-\d{2} \d{2}:\d{2}").Value;
                TxtDiagHead.Text = Diagnosis.Header(text) + "\nReport: " + path;
                RefreshDiagPlan();
                Log("Diagnosis on screen: " + _diagLayers.Count(l => !l.Ok) + " of " + Format.Count(_diagLayers.Count, "layer", "layers") + " with a finding.");
            }
            catch (Exception ex) { Log("The diagnosis report could not be read: " + ex.Message); }
            UpdateDash();
        }

        /// <summary>The "What to do" card, from the cards as they stand: hidden while a run reads or before any report, otherwise the steps and the notes.</summary>
        private void RefreshDiagPlan()
        {
            var plan = Diagnosis.Plan(_diagLayers, _diagReportPath.Length > 0);
            CardPlan.Visibility = plan.Visible ? Visibility.Visible : Visibility.Collapsed;
            TxtPlanSummary.Text = plan.Summary;
            ListPlan.ItemsSource = plan.Steps;
            ListPlanNotes.ItemsSource = plan.Notes;
            TxtPlanNotesHead.Visibility = plan.Notes.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        }

        // ------------------------------------------------------------------ Disk Management

        private async Task LoadDisksAsync()
        {
            if (_diskLoading) return;
            _diskLoading = true;
            // the indicator: a spinner on the panel, the sentence beside it, and the strip's hint -
            // elevated, the read asks every volume how far it can shrink, which takes seconds
            EmptyDisk.Text = "Reading the disks...";
            DiskSpinner.Visibility = Visibility.Visible;
            PanelDiskEmpty.Visibility = Visibility.Visible;
            ScrollDisk.Visibility = Visibility.Collapsed;
            BtnDiskRescan.IsEnabled = false;
            if (_toolsSubTab == "Disk") TxtToolsHint.Text = "reading the disks - each volume is asked how far it can shrink...";
            try
            {
                var json = await _reader.RunAsync("disks", null, null, CancellationToken.None, 120);
                _disks = DiskTools.ParseLayout(json);
                _diskLoaded = true;
                BuildDiskPanel();
                Log("Disks: " + Format.Count(_disks.Count, "disk", "disks") + ", " + Format.Count(_disks.Sum(d => d.Partitions.Count), "partition", "partitions") +
                    (App.Elevated ? "." : " - not elevated, so the shrink limits are unknown."));
            }
            catch (Exception ex)
            {
                Log("Disks: the layout could not be read - " + ex.Message);
                EmptyDisk.Text = "The disks could not be read.\n\n" + ex.Message;
            }
            finally
            {
                _diskLoading = false;
                DiskSpinner.Visibility = Visibility.Collapsed;
                BtnDiskRescan.IsEnabled = true;
                if (_toolsSubTab == "Disk") TxtToolsHint.Text = DiskHint;
                UpdateDash();
            }
        }

        private const string DiskHint = "Shrink and Extend act on the volume you choose; the reason is shown whenever Extend cannot simply extend.";

        private static readonly Dictionary<string, string> KindColour = new Dictionary<string, string>(StringComparer.Ordinal)
        {
            { "volume", "#FF2563EB" }, { "system", "#FF64748B" }, { "reserved", "#FF3C3C45" }, { "recovery", "#FFF59E0B" }, { "other", "#FF4B5563" }, { "gap", "#FF17171B" },
        };

        /// <summary>One bar per disk, proportional, then a row per volume with Shrink and Extend and the reason when Extend cannot simply extend.</summary>
        private void BuildDiskPanel()
        {
            PanelDisks.Children.Clear();
            if (_disks.Count == 0) { EmptyDisk.Text = "No disks were reported."; DiskSpinner.Visibility = Visibility.Collapsed; PanelDiskEmpty.Visibility = Visibility.Visible; return; }
            foreach (var d in _disks)
            {
                var card = new Border { CornerRadius = new CornerRadius(10), Background = Res("Panel"), BorderBrush = Res("Line"), BorderThickness = new Thickness(1), Margin = new Thickness(0, 0, 0, 10), Padding = new Thickness(14, 12, 14, 12) };
                var stack = new StackPanel();
                card.Child = stack;
                var head = new TextBlock { FontSize = 13, FontWeight = FontWeights.SemiBold, Foreground = Res("Ink"),
                    Text = "Disk " + d.Number + "  ·  " + d.Name + "  ·  " + Format.Size(d.Size) + "  ·  " + d.Style + (d.Bus.Length > 0 ? "  ·  " + d.Bus : "") + (d.IsBoot ? "  ·  Windows boots from here" : "") + (d.IsDynamic ? "  ·  DYNAMIC DISK - cannot be resized here" : "") };
                stack.Children.Add(head);
                // the bar: one column per partition and per gap, star-sized by bytes, with a floor so a 100 MB system partition is still visible
                var bar = new Grid { Height = 26, Margin = new Thickness(0, 10, 0, 6) };
                var segs = new List<KeyValuePair<PartInfo, long>>();
                long cursor = 0;
                // alignment slack of a few megabytes is not "free space" a technician can use - only gaps of 8 MB or more are drawn (the same floor Extend uses)
                var slack = DiskTools.Slack;
                foreach (var p in d.Partitions)
                {
                    if (p.Offset > cursor + slack) segs.Add(new KeyValuePair<PartInfo, long>(null, p.Offset - cursor));
                    segs.Add(new KeyValuePair<PartInfo, long>(p, p.Size));
                    cursor = p.Offset + p.Size;
                }
                if (d.Size > cursor + slack) segs.Add(new KeyValuePair<PartInfo, long>(null, d.Size - cursor));
                var floor = d.Size / 60.0;
                var col = 0;
                foreach (var s in segs)
                {
                    bar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(Math.Max(floor, s.Value), GridUnitType.Star) });
                    var p = s.Key;
                    var seg = new Border { CornerRadius = new CornerRadius(4), Margin = new Thickness(1, 0, 1, 0), Background = Brush(KindColour[p == null ? "gap" : (KindColour.ContainsKey(p.Kind) ? p.Kind : "other")]) };
                    if (p == null) { seg.BorderBrush = Res("Line"); seg.BorderThickness = new Thickness(1); }
                    seg.ToolTip = p == null ? "Unallocated  ·  " + Format.Size(s.Value) : p.Title + "  ·  " + DiskTools.RowText(p) + "  ·  partition " + p.Number;
                    var lbl = new TextBlock { Text = p == null ? "free" : p.Title, FontSize = 10.5, Foreground = Brushes.White, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis, Margin = new Thickness(4, 0, 4, 0) };
                    // a sliver (the 16 MB reserved partition, a 200 MB system partition) has room for an ellipsis and nothing else - the tooltip carries its name
                    if (s.Value < d.Size * 0.035) lbl.Visibility = Visibility.Collapsed;
                    seg.Child = lbl;
                    Grid.SetColumn(seg, col++);
                    bar.Children.Add(seg);
                }
                stack.Children.Add(bar);
                foreach (var p in d.Partitions)
                {
                    var row = new Grid { Margin = new Thickness(0, 4, 0, 4) };
                    row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                    row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                    row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                    var txt = new StackPanel();
                    var t1 = new TextBlock { FontSize = 12.5, Foreground = Res("Ink"), Text = p.Title + (p.Kind == "volume" ? "" : "  (" + p.Kind + " partition)") };
                    var t2 = new TextBlock { FontSize = 11, Foreground = Res("Dim"), Text = DiskTools.RowText(p), TextWrapping = TextWrapping.Wrap };
                    txt.Children.Add(t1); txt.Children.Add(t2);
                    if (p.Kind == "volume")
                    {
                        var plan = DiskTools.Extend(d, p);
                        var room = DiskTools.ShrinkRoom(p);
                        var note = new TextBlock { FontSize = 11, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 3, 0, 0) };
                        if (plan.Kind == "extend") { note.Text = Format.Size(plan.Bytes) + " of free space directly behind it - Extend joins it to this volume."; note.Foreground = Res("Good"); }
                        else if (plan.Kind == "move") { note.Text = plan.Reason + ". Extend moves the recovery partition to the end of the disk and gains about " + Format.Size(plan.Bytes) + "."; note.Foreground = Res("Warn"); }
                        else { note.Text = "Extend: " + plan.Reason + "."; note.Foreground = Res("Dim"); }
                        note.Text += room > 0 ? "  Shrink: up to " + Format.Size(room) + "." : (p.MinSize == 0 ? "  Shrink limit unknown until the tool runs elevated." : "  Shrink: nothing - unmovable files reach the end of the volume.");
                        txt.Children.Add(note);
                        var dd = d; var pp = p; var pl = plan; var rm = room;
                        var bShrink = new Button { Content = "Shrink...", Style = (Style)FindResource("GhostBtn"), Margin = new Thickness(8, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center, IsEnabled = rm > 0 && !dd.IsDynamic };
                        bShrink.Click += (s, e) => OnDiskShrink(dd, pp, rm);
                        var bExt = new Button { Content = pl.Kind == "move" ? "Move recovery + Extend..." : "Extend...", Style = (Style)FindResource(pl.Kind == "none" ? "GhostBtn" : "AccentBtn"), Margin = new Thickness(8, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center, IsEnabled = pl.Kind != "none" };
                        bExt.Click += (s, e) => OnDiskExtend(dd, pp, pl);
                        Grid.SetColumn(bShrink, 1); Grid.SetColumn(bExt, 2);
                        row.Children.Add(bShrink); row.Children.Add(bExt);
                    }
                    Grid.SetColumn(txt, 0);
                    row.Children.Add(txt);
                    stack.Children.Add(row);
                }
                PanelDisks.Children.Add(card);
            }
            PanelDiskEmpty.Visibility = Visibility.Collapsed;
            ScrollDisk.Visibility = Visibility.Visible;
        }

        private void OnDiskShrink(DiskInfo d, PartInfo p, long room)
        {
            if (TestBatchBusy()) return;
            TxtDiskTitle.Text = "Shrink " + p.Title;
            TxtDiskSub.Text = p.Title + " is " + Format.Size(p.Size) + " with " + Format.Size(p.Free) + " free. Windows can give up at most " + Format.Size(room) + " - unmovable files (the pagefile, hibernation, shadow copies) sit at the end of the volume. The space freed becomes unallocated directly behind it.";
            TxtDiskGb.Text = Math.Floor(room / (double)(1L << 30)).ToString(CultureInfo.InvariantCulture);
            TxtDiskHint.Text = "Whole or decimal gigabytes, up to " + Format.Size(room) + ".";
            _diskDialogOk = bytes =>
            {
                if (bytes <= 0 || bytes > room) { TxtDiskHint.Text = "Enter an amount between 0.1 GB and " + Format.Size(room) + "."; return; }
                DiskOverlay.Visibility = Visibility.Collapsed;
                StartDiskBatch("diskshrink", d, p, bytes, "Shrink " + p.Title + " by " + Format.Size(bytes));
            };
            FadeIn(DiskOverlay);
        }

        private void OnDiskExtend(DiskInfo d, PartInfo p, ExtendPlan plan)
        {
            if (TestBatchBusy()) return;
            if (plan.Kind == "extend")
            {
                TxtDiskTitle.Text = "Extend " + p.Title;
                TxtDiskSub.Text = Format.Size(plan.Bytes) + " of unallocated space sits directly behind " + p.Title + ". Windows joins it to the volume in place; nothing on the volume moves and nothing is lost.";
                var gb = Math.Floor(plan.Bytes / (double)(1L << 30) * 10) / 10;
                TxtDiskGb.Text = (gb > 0 ? gb : 0.1).ToString(CultureInfo.InvariantCulture);
                TxtDiskHint.Text = "Up to " + Format.Size(plan.Bytes) + ". Leave the full amount to take all of it.";
                _diskDialogOk = bytes =>
                {
                    if (bytes <= 0) { TxtDiskHint.Text = "Enter an amount above 0."; return; }
                    DiskOverlay.Visibility = Visibility.Collapsed;
                    StartDiskBatch("diskextend", d, p, bytes >= plan.Bytes ? 0 : bytes, "Extend " + p.Title + " by " + Format.Size(Math.Min(bytes, plan.Bytes)));
                };
                FadeIn(DiskOverlay);
                return;
            }
            if (plan.Kind != "move") { ShowOverlay("Cannot extend " + p.Title, plan.Reason + "."); return; }
            var b = plan.Blocker;
            var steps = "1. Disable Windows Recovery so its image returns to the Windows folder.\n" +
                        "2. Delete the recovery partition (" + Format.Size(b.Size) + ", partition " + b.Number + ").\n" +
                        "3. Extend " + p.Title + " into the space, leaving 1 GB at the end.\n" +
                        "4. Create a new recovery partition in that 1 GB, marked the way Windows expects.\n" +
                        "5. Re-enable Windows Recovery so the image lands in it.";
            var warn = "This rewrites the partition table. A restore point cannot undo it. " +
                       (d.IsBoot ? "BitLocker must be suspended on " + p.Title + " first, or step 1 refuses." : "This disk is not the Windows disk, so steps 1 and 5 do not apply.") +
                       "\n\nGain: about " + Format.Size(plan.Bytes) + ". Every step reports before the next one runs.";
            ShowConfirm("Move the recovery partition and extend " + p.Title + "?", plan.Reason + ".\n\n" + steps + "\n\n" + warn, "Continue",
                        () => StartDiskBatch("diskextendmove", d, p, 0, "Extend " + p.Title + " past the recovery partition"));
        }

        private void OnDiskDialogOk()
        {
            double gb;
            if (!double.TryParse((TxtDiskGb.Text ?? "").Trim().Replace(',', '.'), NumberStyles.Float, CultureInfo.InvariantCulture, out gb) || gb <= 0)
            { TxtDiskHint.Text = "Enter a number of gigabytes, such as 20 or 12.5."; return; }
            if (_diskDialogOk != null) _diskDialogOk((long)(gb * (1L << 30)));
        }
    }
}
