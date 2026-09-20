using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Data;
using PC2Go.Deploy.Models;
using PC2Go.Deploy.Services;

namespace PC2Go.Deploy
{
    /// <summary>
    /// The Firewall tab: blocked on the left, everything else on the right, stray rules at the end of
    /// the Blocked column. The scan is the script's own Get-FirewallBlockMap and Load-Firewall helpers
    /// run in the reader; detection reads the machine, not our own bookkeeping, so rules left behind by
    /// an earlier script show up and can be removed. The queue carries an app name and its install
    /// folder, never a list of paths: the elevated worker enumerates the executables and re-applies the
    /// protected-root rules itself.
    /// </summary>
    public partial class MainWindow
    {
        private readonly ObservableCollection<AppItem> _fwItems = new ObservableCollection<AppItem>();
        private ListCollectionView _fwView, _fwOpenView;
        private Dictionary<string, List<FwRule>> _fwMap;
        private bool _fwLoaded, _fwScanning, _fwDirty = true;

        private void WireFirewall()
        {
            // LEFT = anything with an enabled rule, grouped so the strays sit under their own heading
            _fwView = new ListCollectionView(_fwItems);
            _fwView.GroupDescriptions.Add(new PropertyGroupDescription("Category"));
            _fwView.SortDescriptions.Add(new SortDescription("Source", ListSortDirection.Ascending));
            _fwView.SortDescriptions.Add(new SortDescription("Name", ListSortDirection.Ascending));
            _fwView.Filter = o => { var i = o as AppItem; return i != null && i.IsSilent && FilterRow(o); };
            // RIGHT = programs with no rules at all, the only things Block can act on
            _fwOpenView = new ListCollectionView(_fwItems);
            _fwOpenView.SortDescriptions.Add(new SortDescription("Name", ListSortDirection.Ascending));
            _fwOpenView.Filter = o => { var i = o as AppItem; return i != null && !i.IsSilent && FilterRow(o); };
            ListFw.ItemsSource = _fwView;
            ListFwOpen.ItemsSource = _fwOpenView;
            BtnFwRescan.Click += (s, e) => { if (!TestBatchBusy()) { var _ = LoadFirewallAsync(); } };
            BtnFwDetailClose.Click += (s, e) => FwDetailOverlay.Visibility = Visibility.Collapsed;
            // the detail button lives inside the row template, so its Click bubbles to the list -
            // one handler here rather than one per row, and it stays off the checkbox
            var detail = new RoutedEventHandler(OnFwDetailClick);
            ListFw.AddHandler(ButtonBase.ClickEvent, detail);
            ListFwOpen.AddHandler(ButtonBase.ClickEvent, detail);
            BtnFwBlock.Click += (s, e) => { var _ = OnFwBlockClickAsync(); };
            BtnFwUnblock.Click += (s, e) => { var _ = OnFwUnblockClickAsync(); };
            BtnFwRemoveAll.Click += (s, e) => { var _ = OnFwRemoveAllClickAsync(); };
        }

        private void OnFwDetailClick(object sender, RoutedEventArgs e)
        {
            var b = e.OriginalSource as Button;
            if (b == null) return;
            var row = b.DataContext as AppItem;
            if (row == null) return;
            ShowFwDetail(row);
            e.Handled = true;
        }

        private async Task OnFwTabShownAsync()
        {
            // no busy pill here: the panel paints its own spinner
            if (_fwDirty) await LoadFirewallAsync();
        }

        /// <summary>
        /// Load-Firewall: one scan at a time (the tab pressed again mid-scan used to clear the list the
        /// outer scan was still filling), the spinner's two stages from the reader's progress line, then
        /// the rows with their real program icons - a wall of identical placeholder glyphs made this
        /// list unreadable.
        /// </summary>
        private async Task LoadFirewallAsync()
        {
            if (_fwScanning) return;
            _fwScanning = true;
            FwSplit.Visibility = Visibility.Collapsed;
            LoadFw.Visibility = Visibility.Visible;
            TxtLoadFw.Text = "Reading firewall rules...";
            _fwItems.Clear();
            _fwMap = null;
            try
            {
                var json = await _reader.RunAsync("firewall", null, line => Dispatcher.BeginInvoke(new Action(() => TxtLoadFw.Text = line)), CancellationToken.None, 300);
                var load = FirewallList.Parse(json);
                _fwMap = load.Map;
                _suspendDash = true;
                try
                {
                    foreach (var r in load.Rows)
                    {
                        var u = FirewallList.Row(r);
                        u.IconSources = r.IconSources;
                        u.PropertyChanged += (s, e) => { if (e.PropertyName == "IsSelected") UpdateDash(); };
                        _fwItems.Add(u);
                        // the program's own icon, same as the Uninstall tab; a stray takes it from a blocked executable
                        if (r.IconSources.Length > 0) _icons.RequestExe(u, r.IconSources);
                    }
                }
                finally { _suspendDash = false; }
                var offTotal = _fwItems.Sum(FirewallList.OffCount);
                TxtFwHint.Text = FirewallList.Hint(load.RuleTotal, load.Orphans, offTotal);
                _fwLoaded = true;
                Log("Firewall: " + Format.Count(_fwItems.Count, "row", "rows") + ", " + Format.Count(load.RuleTotal, "outbound block rule", "outbound block rules") + ", " + _fwItems.Count(i => i.IsSilent) + " blocked, " + load.Orphans + " unmatched.");
            }
            catch (Exception ex)
            {
                Log("Firewall scan failed: " + ex.Message);
                ShowOverlay("Could not read firewall rules", ex.Message);
            }
            finally
            {
                _fwScanning = false;
                LoadFw.Visibility = Visibility.Collapsed;
                FwSplit.Visibility = Visibility.Visible;
                _fwDirty = false;
                try { _fwView.Refresh(); _fwOpenView.Refresh(); } catch { }
                UpdateFwFilters();
                UpdateFwEmpty();
                UpdateDash();
            }
        }

        /// <summary>Headers carry the counts, and Remove ALL is live only when there is something to remove.</summary>
        private void UpdateFwFilters()
        {
            var blocked = _fwItems.Count(i => i.IsSilent && !FirewallList.IsStray(i));
            var open = _fwItems.Count(i => !i.IsSilent);
            var orph = _fwItems.Count(FirewallList.IsStray);
            var offOnly = _fwItems.Count(i => !i.IsSilent && FirewallList.OffCount(i) > 0);
            TxtFwBlockedHdr.Text = "Blocked   " + blocked + (orph > 0 ? "   +   " + orph + " stray" : "");
            TxtFwOpenHdr.Text = "Not blocked   " + open;
            BtnFwRemoveAll.IsEnabled = (blocked + orph + offOnly) > 0;
        }

        private void UpdateFwEmpty()
        {
            var searching = !string.IsNullOrWhiteSpace(_searchText);
            EmptyFw.Visibility = Visibility.Collapsed;
            if (_fwView.Count == 0)
            {
                EmptyFw.Text = searching ? "Nothing blocked matches \"" + _searchText + "\"." : "Nothing is blocked.\n\nTick a program on the right, then press Block Internet Access.";
                EmptyFw.Visibility = Visibility.Visible;
            }
            EmptyFwOpen.Visibility = Visibility.Collapsed;
            if (_fwOpenView.Count == 0)
            {
                EmptyFwOpen.Text = searching ? "Nothing here matches \"" + _searchText + "\"." : "Every installed program already has block rules.";
                EmptyFwOpen.Visibility = Visibility.Visible;
            }
        }

        private void FwSearchCount(bool searching, string q)
        {
            BtnTabFw.Content = searching && _fwLoaded ? "Firewall   " + (_fwView.Count + _fwOpenView.Count) : "Firewall";
            if (_fwLoaded) UpdateFwEmpty();
        }

        private string FwDashText()
        {
            var sel = _fwItems.Where(i => i.IsSelected).ToList();
            var blk = sel.Count(i => i.IsSilent);
            // the group headers already count the blocked and the not blocked; the dash is for the selection
            return sel.Count > 0 ? sel.Count + " selected  (" + blk + " already blocked, " + (sel.Count - blk) + " not)"
                                 : "Tick programs to block or unblock";
        }

        /// <summary>
        /// Show-FwDetail: what a row covers, exactly. For something already blocked this lists the
        /// executables that have rules, from the map captured during the scan; for an untouched program
        /// it is a PREVIEW of what pressing Block would create - the same list the worker will enumerate.
        /// </summary>
        private void ShowFwDetail(AppItem row)
        {
            var root = (row.UnArgs ?? "").TrimEnd('\\');
            var stray = FirewallList.IsStray(row);
            var lines = new List<string>();
            if (row.IsSilent)
            {
                int exes;
                lines = FirewallList.BlockedDetail(_fwMap, root, out exes);
                TxtFwDetailTitle.Text = row.Name + " - blocked";
                TxtFwDetailSub.Text = stray
                    ? "Outbound block rules cover " + Format.Count(exes, "executable", "executables") + " under " + root + ", but no installed program owns this folder. Unblocking removes them."
                    : "Outbound block rules currently cover " + Format.Count(exes, "executable", "executables") + " under " + root + ".";
            }
            else
            {
                if (root.Length == 0 || !Directory.Exists(root))
                {
                    TxtFwDetailTitle.Text = row.Name;
                    TxtFwDetailSub.Text = "The install folder no longer exists: " + root;
                    TxtFwDetail.Text = "";
                    FwDetailOverlay.Visibility = Visibility.Visible;
                    return;
                }
                var exes = FirewallList.EnumerateExes(root);
                const int cap = 400;
                lines.AddRange(exes.OrderBy(x => x, StringComparer.Ordinal).Take(cap));
                if (exes.Count > cap) { lines.Add(""); lines.Add("... and " + (exes.Count - cap) + " more (list truncated for display; all of them would be blocked)"); }
                TxtFwDetailTitle.Text = row.Name + " - not blocked";
                TxtFwDetailSub.Text = "Pressing Block Internet Access would create one outbound rule per executable under " + root + " - " + Format.Count(exes.Count, "executable", "executables") + ".";
            }
            if (lines.Count == 0) lines.Add("(nothing found)");
            TxtFwDetail.Text = string.Join("\r\n", lines);
            FadeIn(FwDetailOverlay);
        }

        // ------------------------------------------------------------------ the batches

        private async Task OnFwBlockClickAsync()
        {
            if (TestBatchBusy()) return;
            var all = _fwItems.Where(i => i.IsSelected).ToList();
            if (all.Count == 0) { ShowOverlay("Nothing selected", "Tick the programs you want to cut off from the internet."); return; }
            // An Unmatched row is a SHARED vendor tree (Common Files\Adobe and the like), not an
            // application. Blocking it would write rules across components other products depend on -
            // and the worker's Test-FwRoot would not stop it, because it refuses "Common Files" itself
            // but not a vendor folder inside it. These rows exist to be CLEARED, never to be blocked.
            var shared = all.Where(FirewallList.IsStray).ToList();
            var sel = all.Where(i => !FirewallList.IsStray(i)).ToList();
            if (sel.Count == 0)
            {
                ShowOverlay("Nothing blockable selected",
                    "Only Unmatched entries are ticked. Those are shared vendor folders that belong to no single " +
                    "program - blocking them would cut off components other applications rely on.\n\n" +
                    "Use Unblock Selected to clear their leftover rules instead.");
                return;
            }
            // Blocking is outbound only. Windows already drops unsolicited inbound traffic, so
            // inbound rules would double the rule count for no practical gain.
            // The running-program check asks every process for its path, and each protected one
            // refuses with an exception - a few hundred of those take seconds, so it runs off the
            // window with the busy pill up rather than leaving the press unanswered.
            var roots = sel.Select(s => (s.UnArgs ?? "").TrimEnd('\\') + "\\").ToList();
            TxtBusy.Text = "Checking which of these are running...";
            BusyOverlay.Visibility = Visibility.Visible;
            List<string> running;
            try
            {
                running = await Task.Run(() =>
                {
                    var found = new List<string>();
                    Process[] procs;
                    try { procs = Process.GetProcesses(); } catch { procs = new Process[0]; }
                    foreach (var root in roots)
                        foreach (var p in procs)
                        {
                            try
                            {
                                var path = p.MainModule.FileName;
                                if (!string.IsNullOrEmpty(path) && path.StartsWith(root, StringComparison.OrdinalIgnoreCase)) { found.Add(p.ProcessName); break; }
                            }
                            catch { }   // another user's or a protected process: its path is not ours to read
                        }
                    return found;
                });
            }
            finally { BusyOverlay.Visibility = Visibility.Collapsed; }
            var msg = "Every .exe inside " + Format.Count(sel.Count, "program folder", "program folders") + " gets an outbound block rule:\n\n" +
                      string.Join("\n", sel.Take(8).Select(i => "  - " + i.Name));
            if (sel.Count > 8) msg += "\n  - ...and " + (sel.Count - 8) + " more";
            msg += "\n\nThe programs still run - they just cannot reach the network. Rules are tagged " +
                   "\"" + FirewallList.Group + "\" so Unblock and Remove ALL can find every one of them later.";
            if (shared.Count > 0) msg += "\n\n" + Format.Count(shared.Count, "Unmatched entry", "Unmatched entries") + " skipped - shared vendor folders are never blocked.";
            // nothing is blocked twice: each executable is checked against the live rule table
            var already = sel.Where(i => i.IsSilent).ToList();
            if (already.Count > 0)
            {
                var have = already.Sum(FirewallList.OnCount);
                msg += "\n\n" + already.Count + " of these already have rules (" + have + " in total). Every executable is checked " +
                       "against the live firewall table first, so those are reported as already blocked and skipped - " +
                       "running this twice adds nothing.";
            }
            if (running.Count > 0)
                msg += "\n\nNote: " + string.Join(", ", running.Distinct()) + " is running now. A block only applies to NEW connections, so close and reopen it for the change to bite.";
            ShowConfirm("Block internet access?", msg, "Continue", () => StartFwBatch("fwblock", sel));
        }

        /// <summary>The live rule table, read again at confirm time so the foreign count is about the rules that exist NOW - a few seconds in the reader, behind the busy pill.</summary>
        private async Task<int> ForeignRuleCountAsync(List<AppItem> rows)
        {
            TxtBusy.Text = "Reading the live firewall rules...";
            BusyOverlay.Visibility = Visibility.Visible;
            try
            {
                var json = await _reader.RunAsync("fwmap", null, null, CancellationToken.None, 180);
                return FirewallList.ForeignRuleCount(FirewallList.ParseMap(json), rows);
            }
            catch { return 0; }
            finally { BusyOverlay.Visibility = Visibility.Collapsed; }
        }

        private async Task OnFwUnblockClickAsync()
        {
            if (TestBatchBusy()) return;
            var sel = _fwItems.Where(i => i.IsSelected).ToList();
            if (sel.Count == 0) { ShowOverlay("Nothing selected", "Tick the programs whose block rules you want removed."); return; }
            var withRules = sel.Where(FirewallList.HasRules).ToList();
            if (withRules.Count == 0) { ShowOverlay("Nothing to unblock", "None of the selected programs currently has an outbound block rule."); return; }
            var total = withRules.Sum(s => FirewallList.OnCount(s) + FirewallList.OffCount(s));
            Cursor = System.Windows.Input.Cursors.Wait;
            int foreign;
            try { foreign = await ForeignRuleCountAsync(withRules); } finally { Cursor = null; }
            var msg = Format.Count(total, "rule", "rules") + " across " + Format.Count(withRules.Count, "entry", "entries") + " will be deleted, restoring internet access.\n\n" +
                      (foreign > 0
                          ? foreign + " of them were created by something other than this tool - most likely an earlier script. They are removed too, which is how those leftovers finally get cleared."
                          : "All of them were created by this tool.");
            ShowConfirm("Remove these block rules?", msg, "Continue", () => StartFwBatch("fwunblock", withRules));
        }

        private async Task OnFwRemoveAllClickAsync()
        {
            if (TestBatchBusy()) return;
            var blocked = _fwItems.Where(FirewallList.HasRules).ToList();
            var total = blocked.Sum(s => FirewallList.OnCount(s) + FirewallList.OffCount(s));
            if (total == 0) { ShowOverlay("Nothing to remove", "No outbound block rules were found for any installed program."); return; }
            Cursor = System.Windows.Input.Cursors.Wait;
            int foreign;
            try { foreign = await ForeignRuleCountAsync(blocked); } finally { Cursor = null; }
            var unmatched = blocked.Count(FirewallList.IsStray);
            var msg = Format.Count(total, "outbound block rule", "outbound block rules") + " across " + Format.Count(blocked.Count, "entry", "entries") + " will be deleted.\n\n" +
                      "Everything currently cut off regains internet access.\n";
            if (unmatched > 0) msg += "That includes " + Format.Count(unmatched, "Unmatched entry", "Unmatched entries") + " - rules belonging to no installed program.\n";
            msg += "\n" + (foreign > 0 ? Format.Count(foreign, "rule", "rules") + " created by something other than this tool will also go." : "All of them were created by this tool.");
            ShowConfirm("Remove every block rule?", msg, "Continue", () => StartFwBatch("fwunblock", blocked));
        }

        /// <summary>
        /// Start-FwBatch: one row per program, so each reports its own rule count. An Unmatched row
        /// lives under a shared root the worker's Test-FwRoot refuses by design, so it is removed by
        /// explicit rule NAME instead - the worker re-verifies each named rule is an outbound Block rule
        /// under that folder before touching it.
        /// </summary>
        private void StartFwBatch(string action, List<AppItem> sel)
        {
            foreach (var s in sel) { SetStatus(s, "Queued", "neutral"); SetRing(s, "queued"); }
            _pending = sel.ToList();
            _batchTab = "Fw";
            _runStarted = DateTime.Now;
            _dlIndex = 0; _lastLogKey.Clear();
            _hadFailures = false; _cancelRequested = false; _awaitingScan = false;
            _deepClean = false; _forceMode = false;
            _worker.ResetForBatch();
            ShowBatchStrip();
            if (!_worker.Start()) { AbortBatch("the administrator prompt was declined, so nothing was run", "warn"); return; }
            foreach (var s in sel) _worker.Enqueue(FirewallList.Entry(action, s, App.BuildTag));
            _worker.Complete();
            _phase = "Install";
            BtnFwBlock.IsEnabled = false;
            BtnFwUnblock.IsEnabled = false;
            BtnInstall.IsEnabled = false;
            TxtNow.Text = action == "fwblock" ? "Adding firewall rules..." : "Removing firewall rules...";
            DotNow.Fill = Brush("#FF4C8DFF");
            RowNow.Visibility = Visibility.Visible;
            TxtStatus.Text = TxtNow.Text;
            _fwDirty = true;
            Log("Firewall batch: " + action + " for " + Format.Count(sel.Count, "program", "programs") + ".");
            UpdateDash();
        }

        /// <summary>Finish-Batch's Firewall part: the buttons come back and the tab re-scans itself, so what is on screen is what the machine now has.</summary>
        private void OnBatchEndedFw()
        {
            BtnFwBlock.IsEnabled = true;
            BtnFwUnblock.IsEnabled = true;
            if (_batchTab != "Fw") return;
            var _ = LoadFirewallAsync();
        }
    }
}
