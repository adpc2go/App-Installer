using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Security.Principal;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Data;
using System.Windows.Input;
using PC2Go.Deploy.Models;
using PC2Go.Deploy.Services;

namespace PC2Go.Deploy
{
    /// <summary>
    /// The Optimize tab, Tweaks and Cleanup sub-tabs (Gaming is the last slice to move). The rows
    /// come from the script's own table through the reader; the detectors - "is this already
    /// applied?" - are the script's own scriptblocks, run in the reader as the technician, so
    /// HKCU is the technician's hive. Apply and Undo are the worker's `tweak` / `untweak`
    /// entries with the technician's SID, exactly as the script writes them. Everything here acts
    /// on the sub-tab on screen only - nothing global.
    /// </summary>
    public partial class MainWindow
    {
        private readonly ObservableCollection<AppItem> _tweakItems = new ObservableCollection<AppItem>();
        private readonly ObservableCollection<AppItem> _cleanItems = new ObservableCollection<AppItem>();
        // the Startup sub-tab: this machine's own entries, from the reader, grouped by Task Manager's verdict
        private readonly ObservableCollection<AppItem> _startupItems = new ObservableCollection<AppItem>();
        // the Gaming sub-tab: the gaming-customer persona's rows, with the latency probe as their evidence
        private readonly ObservableCollection<AppItem> _gameItems = new ObservableCollection<AppItem>();
        private ListCollectionView _tweakView, _cleanView, _startupView, _gameView;
        private string _optSubTab = "Tweaks";
        private bool _optLoaded, _optLoading, _tweakChecking, _suspendDash, _needExplorerRestart, _needSettingBroadcast, _startupLoaded, _startupLoading;
        private Optimize.GameProbe _gameBaseline;   // measured before Apply Gaming; the batch end measures again and compares
        private bool _gameMeasuring;
        private readonly List<GameCard> _gameCards = GameCards.Skeleton();   // the probe explained: three cards, grey until measured

        private void WireOptimize()
        {
            _tweakView = (ListCollectionView)CollectionViewSource.GetDefaultView(_tweakItems);
            _tweakView.GroupDescriptions.Add(new PropertyGroupDescription("Category"));
            _tweakView.Filter = FilterRow;
            _cleanView = (ListCollectionView)CollectionViewSource.GetDefaultView(_cleanItems);
            _cleanView.GroupDescriptions.Add(new PropertyGroupDescription("Category"));
            _cleanView.Filter = FilterRow;
            _startupView = (ListCollectionView)CollectionViewSource.GetDefaultView(_startupItems);
            _startupView.GroupDescriptions.Add(new PropertyGroupDescription("Category"));
            _startupView.SortDescriptions.Add(new System.ComponentModel.SortDescription("Category", System.ComponentModel.ListSortDirection.Ascending));
            _startupView.SortDescriptions.Add(new System.ComponentModel.SortDescription("Name", System.ComponentModel.ListSortDirection.Ascending));
            _startupView.Filter = FilterRow;
            _gameView = (ListCollectionView)CollectionViewSource.GetDefaultView(_gameItems);
            _gameView.GroupDescriptions.Add(new PropertyGroupDescription("Category"));
            _gameView.Filter = FilterRow;
            ListTweak.ItemsSource = _tweakView;
            ListClean.ItemsSource = _cleanView;
            ListStartup.ItemsSource = _startupView;
            ListGame.ItemsSource = _gameView;
            ListGameCards.ItemsSource = _gameCards;
            BtnMeasure.Click += (s, e) => { if (!TestTweakListBusy()) { var _ = MeasureGamingAsync("now", true); } };
            // sub-tab switches, Reset and Detect only tick boxes or read the machine - never blocked by a running batch
            BtnSubTweaks.Click += (s, e) => SelectOptTab("Tweaks");
            BtnSubClean.Click += (s, e) => SelectOptTab("Clean");
            BtnSubStartup.Click += (s, e) => SelectOptTab("Startup");
            BtnSubGame.Click += (s, e) => SelectOptTab("Game");
            BtnSelAll.Click += (s, e) => SetOptSelection(true);
            BtnSelNone.Click += (s, e) => SetOptSelection(false);
            BtnPreClear.Click += (s, e) => OnPreClear();
            BtnDetect.Click += (s, e) => { if (!TestTweakListBusy()) { var _ = InvokeTweakDetectAsync(); } };
            BtnTweakUndo.Click += (s, e) => OnTweakUndoClick();
            BtnTweakApply.Click += (s, e) => OnTweakApplyClick();
        }

        private async Task OnOptimizeTabShownAsync()
        {
            SelectOptTab(_optSubTab);
            await EnsureTweaksLoadedAsync();
        }

        private Task _optLoadTask, _startupLoadTask;

        /// <summary>The tweak table once, whoever asks first - the tab, or a Diagnose remedy that needs a row before the tab was ever opened.</summary>
        private Task EnsureTweaksLoadedAsync()
        {
            if (_optLoaded) return Task.FromResult(0);
            if (_optLoadTask == null || _optLoadTask.IsCompleted) _optLoadTask = LoadTweakTableAsync();
            return _optLoadTask;
        }

        private async Task LoadTweakTableAsync()
        {
            if (_optLoading) return;
            _optLoading = true;
            TxtBusy.Text = "Loading the tweaks...";
            BusyOverlay.Visibility = Visibility.Visible;
            try
            {
                var json = await _reader.RunAsync("tweakdefs", null, null, CancellationToken.None, 60);
                LoadTweaks(Optimize.ParseDefs(json));
                _optLoaded = true;
            }
            catch (Exception ex)
            {
                Log("Optimize: the tweak table could not be read - " + ex.Message);
                EmptyTweak.Text = "The tweak list could not be read.\n\n" + ex.Message;
                EmptyTweak.Visibility = Visibility.Visible;
            }
            finally
            {
                BusyOverlay.Visibility = Visibility.Collapsed;
                _optLoading = false;
                UpdateDash();
            }
        }

        /// <summary>Load-Tweaks: each list arrives pre-configured - everything ticked except CAUTION - so the everyday flow is open the sub-tab and press Apply.</summary>
        private void LoadTweaks(List<TweakDef> defs)
        {
            _tweakItems.Clear(); _cleanItems.Clear(); _gameItems.Clear();
            _suspendDash = true;   // one dashboard refresh for the whole load
            try
            {
                foreach (var t in defs)
                {
                    var item = new AppItem
                    {
                        Id = "tweak-" + t.Id, Name = t.Name, Size = "", UnArgs = t.Id, IsSilent = !t.Caution,
                        Publisher = t.Tab == "cleanup" ? "Cleanup action" : (t.Tab == "gaming" ? "Gaming tweak" : "System tweak"),
                        Category = t.Caution ? "CAUTION - tick deliberately" : (t.Tab == "cleanup" ? "Cleanup" : (t.Tab == "gaming" ? "Gaming" : "Tweaks")),
                        IconBg = t.Caution ? "#FFF59E0B" : "#FF2563EB", IconData = Catalog.IconMap["default"][0], RowOpacity = 1.0,
                        IsSelected = !t.Caution,
                    };
                    item.PropertyChanged += (s, e) => { if (e.PropertyName == "IsSelected") UpdateDash(); };
                    if (t.Tab == "cleanup") _cleanItems.Add(item); else if (t.Tab == "gaming") _gameItems.Add(item); else _tweakItems.Add(item);
                }
            }
            finally { _suspendDash = false; }
            Log("Optimize loaded: " + _tweakItems.Count + " tweaks (" + _tweakItems.Count(i => i.IsSelected) + " pre-ticked), " +
                _cleanItems.Count + " cleanup actions (" + _cleanItems.Count(i => i.IsSelected) + " pre-ticked), " +
                _gameItems.Count + " gaming tweaks (" + _gameItems.Count(i => i.IsSelected) + " pre-ticked).");
        }

        /// <summary>
        /// The rows actually on screen. Select All, Clear All and Reset must act on these and not on
        /// the backing collection: with a word in the search box, "Select All" on Cleanup used to
        /// tick every cleanup action in the table while the list showed two - including the one that
        /// removes Windows.old, which cannot be undone. Nothing gets ticked that cannot be seen.
        /// </summary>
        private IList<AppItem> GetOptVisible()
        {
            var v = _optSubTab == "Clean" ? _cleanView : (_optSubTab == "Startup" ? _startupView : (_optSubTab == "Game" ? _gameView : _tweakView));
            if (v == null) return GetOptItems();
            return v.Cast<AppItem>().ToList();
        }

        private IList<AppItem> GetOptItems()
        {
            if (_optSubTab == "Clean") return _cleanItems;
            if (_optSubTab == "Startup") return _startupItems;
            if (_optSubTab == "Game") return _gameItems;
            return _tweakItems;
        }

        private void SelectOptTab(string which)
        {
            _optSubTab = which;
            BtnSubTweaks.Style = (Style)FindResource(which == "Tweaks" ? "TabActive" : "TabIdle");
            BtnSubClean.Style = (Style)FindResource(which == "Clean" ? "TabActive" : "TabIdle");
            BtnSubStartup.Style = (Style)FindResource(which == "Startup" ? "TabActive" : "TabIdle");
            BtnSubGame.Style = (Style)FindResource(which == "Game" ? "TabActive" : "TabIdle");
            ScrollTweaks.Visibility = which == "Tweaks" ? Visibility.Visible : Visibility.Collapsed;
            ScrollClean.Visibility = which == "Clean" ? Visibility.Visible : Visibility.Collapsed;
            ScrollStartup.Visibility = which == "Startup" ? Visibility.Visible : Visibility.Collapsed;
            ScrollGame.Visibility = which == "Game" ? Visibility.Visible : Visibility.Collapsed;
            var onTab = _tab == "Optimize";
            // Undo exists for config tweaks (Tweaks, Gaming) and for a startup entry switched off: cleanup rows are one-time actions
            BtnTweakUndo.Visibility = ((which == "Tweaks" || which == "Startup" || which == "Game") && onTab) ? Visibility.Visible : Visibility.Collapsed;
            BtnTweakUndo.Content = which == "Startup" ? "Switch Back On" : "Undo Selected";
            BtnTweakApply.Visibility = onTab ? Visibility.Visible : Visibility.Collapsed;
            TxtTweakApplyBtn.Text = which == "Clean" ? "Run Cleanup" : (which == "Startup" ? "Switch Off Ticked" : (which == "Game" ? "Apply Gaming" : "Apply Tweaks"));
            BtnDetect.Content = which == "Startup" ? "Rescan" : "Detect Applied";
            // the latency probe is the Gaming sub-tab's evidence tool - meaningless elsewhere
            BtnMeasure.Visibility = which == "Game" ? Visibility.Visible : Visibility.Collapsed;
            // the probe's sentence is long and the strip clips: it lives on the dash, the strip shows only "measuring..."
            if (which == "Game") TxtTweakHint.Text = "";
            else if (which == "Startup")
            {
                TxtTweakHint.Text = _startupLoaded ? StartupHint() : "";
                if (!_startupLoaded && !_startupLoading) _startupLoadTask = LoadStartupAsync();
            }
            else if (which == "Clean")
            {
                // a nearly-full disk is the reason to run these - show it before the decision
                var free = "";
                try
                {
                    var sys = Environment.GetEnvironmentVariable("SystemDrive") ?? "C:";
                    var d = new DriveInfo(sys);
                    var tot = d.TotalSize;
                    if (tot > 0) free = sys + " free: " + Format.Size(d.AvailableFreeSpace) + " of " + Format.Size(tot) + " (" + Math.Round(d.AvailableFreeSpace * 100.0 / tot) + "%)";
                }
                catch { }
                TxtTweakHint.Text = free;
            }
            else TxtTweakHint.Text = "";
            OptSearchCount(!string.IsNullOrWhiteSpace(_searchText), _searchText);
            UpdateDash();
        }

        private string StartupHint()
        {
            // the two group headers already count what starts and what is off; the hint says what the buttons do
            return "Tick entries, then Switch Off Ticked - nothing is uninstalled";   // short: the strip clips, it does not wrap
        }

        /// <summary>The Startup sub-tab's list, from the reader: this account's Run keys and Startup folders with Task Manager's verdict on each.</summary>
        private async Task LoadStartupAsync()
        {
            if (_startupLoading) return;
            _startupLoading = true;
            TxtTweakHint.Text = "reading what starts with Windows...";
            try
            {
                var json = await _reader.RunAsync("startupapps", null, null, CancellationToken.None, 60);
                var entries = Optimize.ParseStartup(json);
                _suspendDash = true;
                try
                {
                    _startupItems.Clear();
                    foreach (var e in entries)
                    {
                        var row = Optimize.StartupRow(e);
                        row.PropertyChanged += (s, ev) => { if (ev.PropertyName == "IsSelected") UpdateDash(); };
                        _startupItems.Add(row);
                        // the program's own icon, off the UI thread, like the Uninstall and Firewall rows
                        if (row.IconSources.Length > 0) _icons.RequestExe(row, row.IconSources);
                    }
                }
                finally { _suspendDash = false; }
                _startupLoaded = true;
                Log("Startup: " + Format.Count(_startupItems.Count, "entry", "entries") + ", " + _startupItems.Count(i => !i.IsSilent) + " switched off.");
                if (_optSubTab == "Startup") TxtTweakHint.Text = StartupHint();
            }
            catch (Exception ex)
            {
                Log("Startup: the list could not be read - " + ex.Message);
                if (_optSubTab == "Startup") TxtTweakHint.Text = "the startup list could not be read - " + ex.Message;
            }
            finally
            {
                _startupLoading = false;
                OptSearchCount(!string.IsNullOrWhiteSpace(_searchText), _searchText);
                UpdateDash();
            }
        }

        /// <summary>Test-TweakListBusy: the toolbar refuses while the rows are being probed or while their batch runs.</summary>
        private bool TestTweakListBusy()
        {
            if (_tweakChecking)
            {
                ShowOverlay("Still checking", "The tweak rows are being probed right now. Wait for the check to finish, then press again.");
                return true;
            }
            if (_gameMeasuring)
            {
                ShowOverlay("Still measuring", "The latency probe is running - about five seconds. Wait for the number, then press again.");
                return true;
            }
            if ((_phase == "Download" || _phase == "Install") && _batchTab == "Tweak")
            {
                ShowOverlay("Tweaks are running", "These rows are showing live progress from the elevated worker right now, so the selection is held until the batch finishes.\n\nEverything else stays available in the meantime.");
                return true;
            }
            return false;
        }

        /// <summary>Select All / Clear All act on the sub-tab on screen only. Select All ticks CAUTION too - the Apply confirm still names every CAUTION row.</summary>
        private void SetOptSelection(bool on)
        {
            if (TestTweakListBusy()) return;
            _suspendDash = true;
            try { foreach (var t in GetOptVisible()) t.IsSelected = on; } finally { _suspendDash = false; }
            UpdateDash();
        }

        /// <summary>Reset returns to the DEFAULT state (ticked except CAUTION), not to all-unticked, and clears any verdict a Detect left.</summary>
        private void OnPreClear()
        {
            if (TestTweakListBusy()) return;
            _suspendDash = true;
            try
            {
                foreach (var t in GetOptVisible())
                {
                    // a startup row's default is UNTICKED: nothing stops starting unless the technician says so
                    t.IsSelected = _optSubTab == "Startup" ? false : t.IsSilent;
                    SetStatus(t, "", "neutral"); SetRing(t, "none");
                }
            }
            finally { _suspendDash = false; }
            TxtTweakHint.Text = "";
            UpdateDash();
        }

        /// <summary>The detectors for a set of ids, through the reader; progress lands on the hint line.</summary>
        private async Task<Dictionary<string, bool?>> ProbeAsync(IEnumerable<string> ids, Action<int, int> progress)
        {
            var list = ids.ToList();
            if (list.Count == 0) return new Dictionary<string, bool?>();
            var json = await _reader.RunAsync("tweakprobe", Json.Serialize(new Dictionary<string, object> { { "ids", list.ToArray() } }), text =>
            {
                if (progress == null) return;
                var parts = (text ?? "").Trim().Split('|');
                int i, n;
                if (parts.Length >= 2 && int.TryParse(parts[0], out i) && int.TryParse(parts[1], out n))
                    Dispatcher.BeginInvoke(new Action(() => progress(i, n)));
            }, CancellationToken.None, 600);
            return Optimize.ParseProbe(json);
        }

        /// <summary>Invoke-TweakDetect: the ACTIVE sub-tab only; a true probe ticks the row and says so, a null one is an action and is left alone.</summary>
        private async Task InvokeTweakDetectAsync()
        {
            // on the Startup sub-tab the button is Rescan: the machine is the state
            if (_optSubTab == "Startup") { _startupLoaded = false; await LoadStartupAsync(); return; }
            var all = GetOptItems().ToList();
            if (all.Count == 0) return;
            var applied = 0; var notDetectable = 0;
            BtnDetect.IsEnabled = false;
            _tweakChecking = true;   // every other button on this toolbar refuses while this runs
            Cursor = Cursors.Wait;
            TxtTweakHint.Text = "detecting... 0 of " + all.Count;
            foreach (var t in all) SetRing(t, "busy");
            _suspendDash = true;
            try
            {
                var res = await ProbeAsync(all.Select(t => t.UnArgs), (i, n) => TxtTweakHint.Text = "detecting... " + i + " of " + n);
                foreach (var t in all)
                {
                    SetRing(t, "none");
                    bool? r;
                    if (!res.TryGetValue(t.UnArgs ?? "", out r)) r = null;
                    if (r == null)
                    {
                        // one-shot action, not a state - never claim it is applied, and leave the tick alone
                        SetStatus(t, "one-time action - cannot be detected", "neutral");
                        notDetectable++;
                    }
                    else if (r == true)
                    {
                        t.IsSelected = true;
                        SetStatus(t, "already applied", "ok");
                        applied++;
                    }
                    else
                    {
                        t.IsSelected = false;
                        SetStatus(t, "", "neutral");
                    }
                }
            }
            catch (Exception ex)
            {
                foreach (var t in all) SetRing(t, "none");
                Log("Detect failed: " + ex.Message);
                TxtTweakHint.Text = "detect failed - " + ex.Message;
                return;
            }
            finally
            {
                _tweakChecking = false;
                _suspendDash = false;
                Cursor = null;
                BtnDetect.IsEnabled = true;
            }
            TxtTweakHint.Text = applied + " already applied, " + notDetectable + " not detectable";
            Log("Detect (" + _optSubTab + "): " + Format.Count(applied, "row", "rows") + " already applied on this machine, " + notDetectable + " are one-time actions that cannot be detected.");
            UpdateDash();
        }

        /// <summary>
        /// Counts the rows ON SCREEN, because Select All, Clear All, Reset, Apply and Undo all act
        /// on those. With an empty search box this is the whole table and the line reads as it
        /// always did; with a word in the box the line and the list finally agree.
        /// </summary>
        private string OptDashText()
        {
            var vis = GetOptVisible();
            var sel = vis.Count(i => i.IsSelected);
            var c = _cleanItems.Count(i => i.IsSelected);
            switch (_optSubTab)
            {
                case "Clean": return sel + " of " + Format.Count(vis.Count, "cleanup task", "cleanup tasks") + " selected";
                case "Startup": return sel + " of " + Format.Count(vis.Count, "startup entry", "startup entries") + " ticked";
                case "Game": return sel + " of " + Format.Count(vis.Count, "gaming tweak", "gaming tweaks") + " selected";
                default:
                    return sel + " of " + Format.Count(vis.Count, "tweak", "tweaks") + " selected" + (c != _cleanItems.Count(i => i.IsSilent) ? "    |    " + c + " cleanup" : "");
            }
        }

        private void OptSearchCount(bool searching, string q)
        {
            var nTweak = _tweakView.Count;
            BtnTabTweak.Content = searching && _optLoaded ? "Optimize   " + nTweak : "Optimize";
            if (!_optLoaded) return;
            EmptyTweak.Visibility = Visibility.Collapsed;
            var shown = _optSubTab == "Clean" ? _cleanView.Count : (_optSubTab == "Startup" ? (_startupLoaded ? _startupView.Count : 1) : (_optSubTab == "Game" ? _gameView.Count : nTweak));
            if (searching && _tab == "Optimize" && shown == 0)
            {
                EmptyTweak.Text = "No tweak matching \"" + q + "\".";
                EmptyTweak.Visibility = Visibility.Visible;
            }
        }

        // ------------------------------------------------------------------ the batches

        private void OnTweakUndoClick()
        {
            if (TestBatchBusy()) return;
            if (_optSubTab == "Startup")
            {
                // Switch Back On: the ticked rows that are currently off
                var back = GetOptVisible().Where(i => i.IsSelected && !i.IsSilent).ToList();
                if (back.Count == 0) { ShowOverlay("Nothing to switch on", "Tick an entry under \"Switched off\" to let it start with Windows again."); return; }
                ShowConfirm("Let these start with Windows again?", string.Join("\n", back.Select(i => "  - " + i.Name)), "Continue", () => StartStartupBatch(back, true));
                return;
            }
            var sel = GetOptVisible().Where(i => i.IsSelected).ToList();
            if (sel.Count == 0)
            {
                ShowOverlay("Nothing selected", "Select at least one tweak to undo. Tip: \"Detect Applied\" ticks everything currently applied on this machine.");
                return;
            }
            // some tweaks delete or run something and simply cannot be put back - say which, up front
            var oneWay = sel.Where(i => Optimize.OneWayIds.Contains(i.UnArgs)).ToList();
            var msg = Format.Count(sel.Count, "tweak", "tweaks") + " will be reset to their Windows default.";
            if (oneWay.Count > 0)
            {
                var names = string.Join("\n", oneWay.Take(8).Select(i => "  - " + i.Name));
                if (oneWay.Count > 8) names += "\n  - ...and " + (oneWay.Count - 8) + " more";
                msg += "\n\n" + oneWay.Count + " of them cannot be fully undone - the policy is reverted but deleted files, cleared history and removed apps are NOT restored:\n" + names;
            }
            ShowConfirm("Undo selected tweaks?", msg, "Continue", () => StartTweakUndo(sel));
        }

        private void OnTweakApplyClick()
        {
            if (TestBatchBusy()) return;
            // Apply acts on the sub-tab on screen - nothing you cannot see gets run
            if (_optSubTab == "Clean")
            {
                var sel = GetOptVisible().Where(i => i.IsSelected).ToList();
                if (sel.Count == 0) { ShowOverlay("Nothing to do", "Tick at least one cleanup task."); return; }
                // There are TWO CAUTION rows on this sub-tab, not one. The sheet was hard-coded for
                // Windows.old, so ticking only "System Restore Space - Cap at 5%" produced a sheet
                // that named an action which was not ticked, promised consequences that would not
                // happen, and said nothing at all about the one that was about to run.
                var caution = sel.Where(i => !i.IsSilent).ToList();
                if (caution.Count == 0) { var _ = StartTweaksAsync(sel); return; }
                ShowConfirm(caution.Count == 1 ? "Run this cleanup task?" : "Run these cleanup tasks?",
                    string.Join("\n\n", caution.Select(i => i.Name + "\n" + Optimize.CleanupCost(i.UnArgs))),
                    "Continue", () => { var _ = StartTweaksAsync(sel); });
                return;
            }
            if (_optSubTab == "Game") { var _ = ApplyGamingAsync(); return; }
            if (_optSubTab == "Startup")
            {
                var off = GetOptVisible().Where(i => i.IsSelected && i.IsSilent).ToList();
                if (off.Count == 0) { ShowOverlay("Nothing to switch off", "Tick an entry under \"Starts with Windows\" to stop it starting."); return; }
                var names = string.Join("\n", off.Take(12).Select(i => "  - " + i.Name));
                if (off.Count > 12) names += "\n  - ...and " + (off.Count - 12) + " more";
                ShowConfirm("Stop these starting with Windows?",
                    Format.Count(off.Count, "entry", "entries") + " will no longer launch at sign-in:\n\n" + names +
                    "\n\nNothing is uninstalled and nothing is deleted - only the switch Task Manager > Startup shows is flipped, and it can be flipped back there or with Switch Back On here. Takes effect at the next sign-in.",
                    "Continue", () => StartStartupBatch(off, false));
                return;
            }
            var selT = GetOptVisible().Where(i => i.IsSelected).ToList();
            if (selT.Count == 0) { ShowOverlay("Nothing to do", "Tick a tweak to apply. The default selection covers every machine; the CAUTION group is per-machine."); return; }
            var risky = selT.Where(i => !i.IsSilent).ToList();
            var hasRestore = selT.Any(i => i.UnArgs == "restorepoint");
            if (risky.Count == 0) { var _ = StartTweaksAsync(selT); return; }   // the default selection applies without a dialog
            // CAUTION tweaks remove software or change security/network posture - name them explicitly
            var namesT = string.Join("\n", risky.Take(8).Select(i => "  - " + i.Name));
            if (risky.Count > 8) namesT += "\n  - ...and " + (risky.Count - 8) + " more";
            var warn = risky.Count + " of the " + Format.Count(selT.Count, "selected tweak", "selected tweaks") + " are in the CAUTION group:\n\n" + namesT + "\n\n" +
                       (hasRestore ? "A restore point is selected and will be created first." : "No restore point is selected. Tick \"Restore Point - Create\" first if you want an undo.");
            ShowConfirm("Apply CAUTION tweaks?", warn, "Continue", () => { var _ = StartTweaksAsync(selT); });
        }

        private static string CurrentSid()
        {
            try { using (var id = WindowsIdentity.GetCurrent()) return id.User.Value; } catch { return ""; }
        }

        // ------------------------------------------------------------------ the Gaming sub-tab

        /// <summary>
        /// Apply Gaming, the script's sheet word for word: pressing it is the moment the technician
        /// declares "this is a gaming machine", so the Xbox-removal row on Tweaks is un-ticked (and
        /// said), an already-removed Xbox is pointed at the Store, every ticked CAUTION row names its
        /// own cost, and the baseline probe runs before the batch so the result is a measured number.
        /// </summary>
        private async Task ApplyGamingAsync()
        {
            var sel = GetOptVisible().Where(i => i.IsSelected).ToList();
            if (sel.Count == 0) { ShowOverlay("Nothing to do", "Tick a gaming tweak to apply. The default selection is every row but CAUTION."); return; }
            var notes = new List<string>();
            var conflict = _tweakItems.Where(i => i.UnArgs == "debloatxbox" && i.IsSelected).ToList();
            if (conflict.Count > 0)
            {
                _suspendDash = true;
                try { foreach (var c in conflict) c.IsSelected = false; } finally { _suspendDash = false; }
                UpdateDash();
                notes.Add("Un-ticked \"Xbox and Gaming - Remove\" on the Tweaks sub-tab - a gaming machine keeps Game Pass and the Xbox app.");
            }
            try
            {
                var xr = await ProbeAsync(new[] { "debloatxbox" }, null);
                bool? gone;
                if (xr.TryGetValue("debloatxbox", out gone) && gone == true)
                    notes.Add("The Xbox and Gaming apps have ALREADY been removed from this machine - reinstall them from the Microsoft Store (search \"Xbox\").");
            }
            catch { }
            var risky = sel.Where(i => !i.IsSilent).ToList();
            var warn = Format.Count(sel.Count, "gaming tweak", "gaming tweaks") + " will be applied.";
            if (risky.Count > 0)
            {
                var lines = risky.Select(r => { string c; return "  - " + (Optimize.GamingCosts.TryGetValue(r.UnArgs ?? "", out c) ? c : r.Name); });
                warn += "\n\nCAUTION:\n" + string.Join("\n", lines);
            }
            if (notes.Count > 0) warn += "\n\n" + string.Join("\n", notes);
            warn += "\n\nA five-second latency probe runs before and after, so the result is a measured number.";
            ShowConfirm("Apply gaming tweaks?", warn, "Continue", () => { var _ = ApplyGamingConfirmedAsync(sel); });
        }

        private async Task ApplyGamingConfirmedAsync(List<AppItem> sel)
        {
            // baseline FIRST, then the batch; the batch end measures again and compares
            var baseline = await MeasureGamingAsync("baseline", false);
            _gameBaseline = baseline;   // null when the probe failed: the batch still runs, without a verdict
            await StartTweaksAsync(sel);
        }

        /// <summary>
        /// The script's Measure-GamingLatency through the reader: unelevated, read-only, about five
        /// seconds. A fresh run ("now", a baseline) resets the three cards to grey and lets the probe's
        /// own narration turn them one by one; the "after" of Apply Gaming keeps the before numbers on
        /// the cards and narrates on the verdict card instead. Returns null on failure.
        /// </summary>
        private async Task<Optimize.GameProbe> MeasureGamingAsync(string label, bool own)
        {
            if (_gameMeasuring) return null;
            _gameMeasuring = true;
            var asAfter = label == "after";
            BtnMeasure.IsEnabled = false;
            if (own) Cursor = System.Windows.Input.Cursors.Wait;
            if (!asAfter) { GameCards.Begin(_gameCards); CardGameVerdict.Visibility = Visibility.Collapsed; }
            else { TxtGameVerdict.Text = "Measuring again after the batch..."; TxtGameVerdictLine.Text = ""; CardGameVerdict.Visibility = Visibility.Visible; }
            try
            {
                var json = await _reader.RunAsync("gameprobe", null, text => Dispatcher.BeginInvoke(new Action(() =>
                {
                    var t = (text ?? "").Trim();
                    if (asAfter) TxtGameVerdict.Text = "Measuring again after the batch - " + t.Replace("measuring... ", "") + "...";
                    else GameCards.ApplyProgress(_gameCards, t);
                })), CancellationToken.None, 120);
                var p = Optimize.ParseGameProbe(json);
                if (p == null) throw new Exception("the probe returned nothing");
                GameCards.Fill(_gameCards, p, asAfter);
                Log("Gaming " + (label == "now" ? "probe" : label) + " - " + Optimize.FormatProbe(p) + "  (p50 is the PowerShell floor; read p99/max)");
                if (label == "now") WriteGameReport(p, null, null);
                return p;
            }
            catch (Exception ex)
            {
                foreach (var c in _gameCards) if (c.State != "filled") { c.Progress = "measurement failed: " + ex.Message; c.State = "pending"; }
                if (asAfter) { TxtGameVerdict.Text = "The after-measurement failed: " + ex.Message; }
                Log("Gaming probe failed: " + ex.Message);
                return null;
            }
            finally
            {
                _gameMeasuring = false;
                BtnMeasure.IsEnabled = true;
                if (own) Cursor = null;
                UpdateDash();
            }
        }

        /// <summary>Every measurement on paper: gameprobe-<stamp>.txt beside the slow-PC reports, the three lines a person can read, and the before/after when there is one.</summary>
        private void WriteGameReport(Optimize.GameProbe before, Optimize.GameProbe after, KeyValuePair<string, string>? cmp)
        {
            try
            {
                var when = DateTime.Now;
                var path = Path.Combine(_cacheDir, "gameprobe-" + when.ToString("yyyyMMdd-HHmmss") + ".txt");
                File.WriteAllText(path, GameCards.ReportText(Environment.MachineName, when, before, after, cmp));
                Log("Gaming probe written: " + path);
            }
            catch (Exception ex) { Log("The gaming probe report could not be written: " + ex.Message); }
        }

        /// <summary>
        /// Finish-Batch's Gaming part: measure again, compare with the baseline, and say what changed.
        /// A spike can only push the number UP, so a WORSE verdict gets one re-measure and keeps the
        /// better of the two - a Defender scan mid-batch must not be billed to the tweaks. An IMPROVED
        /// verdict is not re-tried: floors do not drop by accident.
        /// </summary>
        private async Task FinishGamingAsync(List<AppItem> ran)
        {
            var b = _gameBaseline;
            _gameBaseline = null;
            if (b == null) return;
            var after = await MeasureGamingAsync("after", false);
            if (after == null) return;
            var cmp = Optimize.CompareProbe(b, after);
            if (cmp.Value.StartsWith("WORSE", StringComparison.Ordinal))
            {
                var again = await MeasureGamingAsync("after", false);
                if (again != null && again.PreP99 < after.PreP99) after = again;
                cmp = Optimize.CompareProbe(b, after);
            }
            var pendingReboot = ran.Any(p => p.UnArgs == "hags" && (p.Status ?? "").StartsWith("Applied", StringComparison.Ordinal));
            var note = pendingReboot ? " (GPU scheduling takes effect after the reboot - press Measure again then)" : "";
            TxtGameVerdict.Text = cmp.Value + note;
            TxtGameVerdictLine.Text = cmp.Key;
            CardGameVerdict.Visibility = Visibility.Visible;
            WriteGameReport(b, after, cmp);
            Log("Gaming before/after: " + cmp.Key);
            Log("Gaming verdict: " + cmp.Value + note);
        }

        private void BeginTweakBatch(List<AppItem> rows)
        {
            _pending = rows;
            _batchTab = "Tweak";
            _runStarted = DateTime.Now;
            _dlIndex = 0; _lastLogKey.Clear();
            _hadFailures = false; _cancelRequested = false; _awaitingScan = false;
            _deepClean = false; _forceMode = false;
            _worker.ResetForBatch();
            ShowBatchStrip();
        }

        /// <summary>
        /// Start-Tweaks: CHECK BEFORE APPLY - every row with a real probe is tested now and an
        /// already-applied row is reported and never queued. A null probe (restore point, every
        /// cleanup row) always runs, and a debloat row is never pre-skipped: its probe can only see
        /// the technician's profile while the row removes for every user. The restore point is
        /// queued FIRST - after the other tweaks have run it would be worthless.
        /// </summary>
        private async Task StartTweaksAsync(List<AppItem> sel)
        {
            TxtStatus.Text = "Checking what is already applied...";
            TxtNow.Text = "Checking what is already applied...";
            DotNow.Fill = Brush("#FF4C8DFF");
            RowNow.Visibility = Visibility.Visible;
            foreach (var s in sel) { SetStatus(s, "Checking...", "neutral"); SetRing(s, "busy"); }
            _tweakChecking = true;
            var results = new Dictionary<string, bool?>();
            try { results = await ProbeAsync(sel.Where(s => !(s.UnArgs ?? "").StartsWith("debloat", StringComparison.Ordinal)).Select(s => s.UnArgs), null); }
            catch (Exception ex) { Log("Pre-apply check could not run (" + ex.Message + ") - every row will run."); }
            var run = new List<AppItem>(); var skipped = 0;
            foreach (var s in sel)
            {
                bool? r;
                if (!results.TryGetValue(s.UnArgs ?? "", out r)) r = null;
                if (r == true)
                {
                    SetStatus(s, "Already applied - skipped", "warn"); SetRing(s, "warn");
                    Log(s.Name + " -> already applied on this machine, skipped.");
                    skipped++;
                }
                else { SetStatus(s, "Queued", "neutral"); SetRing(s, "queued"); run.Add(s); }
            }
            // if the survivors are nothing but the restore point, there is nothing left to protect
            var real = run.Where(s => s.UnArgs != "restorepoint").ToList();
            if (real.Count == 0)
            {
                foreach (var s in run.Where(x => x.UnArgs == "restorepoint")) { SetStatus(s, "Skipped - nothing else will run", "warn"); SetRing(s, "warn"); }
                Log("Nothing to do: " + Format.Count(skipped, "row", "rows") + " already applied on this machine.");
                TxtTweakHint.Text = "nothing to do - everything selected is already applied";
                _tweakChecking = false;
                RowNow.Visibility = Visibility.Collapsed;
                UpdateDash();
                TxtStatus.Text = "Nothing to do - everything selected is already applied";
                return;
            }
            _tweakChecking = false;
            if (skipped > 0) Log("Pre-apply check: " + Format.Count(skipped, "row", "rows") + " already applied, " + real.Count + " will run.");
            _needExplorerRestart = run.Any(s => Optimize.ExplorerIds.Contains(s.UnArgs));
            _needSettingBroadcast = _needExplorerRestart;
            var ordered = run.Where(s => s.UnArgs == "restorepoint").Concat(run.Where(s => s.UnArgs != "restorepoint")).ToList();
            foreach (var s in ordered) { SetStatus(s, "Queued", "neutral"); SetRing(s, "queued"); }
            BeginTweakBatch(ordered);
            if (!_worker.Start()) { AbortBatch("the administrator prompt was declined, so nothing was run", "warn"); return; }
            // the worker runs elevated and may be a DIFFERENT account: per-user tweaks land in HKEY_USERS\<sid>
            var sid = CurrentSid();
            foreach (var s in ordered)
                _worker.Enqueue(new Dictionary<string, object> { { "id", s.Id }, { "action", "tweak" }, { "tweak", s.UnArgs ?? "" }, { "userSid", sid } });
            _worker.Complete();
            _phase = "Install";
            BtnTweakApply.IsEnabled = false;
            BtnInstall.IsEnabled = false;
            TxtStatus.Text = "Applying tweaks...";
            TxtNow.Text = "Applying tweaks...";
            DotNow.Fill = Brush("#FF4C8DFF");
            Log("Tweak batch started: " + Format.Count(ordered.Count, "tweak", "tweaks") + ".");
            UpdateDash();
        }

        /// <summary>A startup batch: one `startupoff` / `startupon` entry per row, the technician's SID so HKCU verdicts land in the right hive. No probe - the list IS the state, and it is re-read when the batch ends.</summary>
        private void StartStartupBatch(List<AppItem> rows, bool on)
        {
            _needExplorerRestart = false; _needSettingBroadcast = false;
            foreach (var s in rows) { SetStatus(s, "Queued", "neutral"); SetRing(s, "queued"); }
            BeginTweakBatch(rows.ToList());
            if (!_worker.Start()) { AbortBatch("the administrator prompt was declined, so nothing was run", "warn"); return; }
            var sid = CurrentSid();
            foreach (var s in rows) _worker.Enqueue(Optimize.StartupEntryFor(s, on, sid));
            _worker.Complete();
            _phase = "Install";
            BtnTweakApply.IsEnabled = false;
            BtnTweakUndo.IsEnabled = false;
            BtnInstall.IsEnabled = false;
            TxtStatus.Text = on ? "Switching startup entries back on..." : "Switching startup entries off...";
            TxtNow.Text = TxtStatus.Text;
            DotNow.Fill = Brush("#FF4C8DFF");
            Log("Startup batch: " + (on ? "switch on " : "switch off ") + Format.Count(rows.Count, "entry", "entries") + " - " + string.Join(", ", rows.Select(r => r.Name)) + ".");
            UpdateDash();
        }

        /// <summary>Start-TweakUndo: the same Explorer restart and broadcast as apply - turning a tweak back off must not look as broken as turning it on did.</summary>
        private void StartTweakUndo(List<AppItem> sel)
        {
            _needExplorerRestart = sel.Any(s => Optimize.ExplorerIds.Contains(s.UnArgs));
            _needSettingBroadcast = _needExplorerRestart;
            foreach (var s in sel) { SetStatus(s, "Queued", "neutral"); SetRing(s, "queued"); }
            BeginTweakBatch(sel.ToList());
            if (!_worker.Start()) { AbortBatch("the administrator prompt was declined, so nothing was run", "warn"); return; }
            var sid = CurrentSid();
            foreach (var s in sel)
                _worker.Enqueue(new Dictionary<string, object> { { "id", s.Id }, { "action", "untweak" }, { "tweak", s.UnArgs ?? "" }, { "userSid", sid } });
            _worker.Complete();
            _phase = "Install";
            BtnTweakApply.IsEnabled = false;
            BtnTweakUndo.IsEnabled = false;
            BtnInstall.IsEnabled = false;
            TxtStatus.Text = "Undoing tweaks...";
            TxtNow.Text = "Undoing tweaks...";
            DotNow.Fill = Brush("#FF4C8DFF");
            Log("Tweak undo started: " + Format.Count(sel.Count, "tweak", "tweaks") + ".");
            UpdateDash();
        }

        /// <summary>
        /// Finish-Batch's Optimize parts: the broadcast Windows needs (driven by what was APPLIED,
        /// not by the tab), one Explorer restart per batch when a row changed what it draws, the
        /// closing count, and the post-apply confirmation - the machine asked whether it reports
        /// each row as applied afterwards, so "Applied" is never the tool claiming credit.
        /// </summary>
        private void OnBatchEndedTweak(string summary)
        {
            BtnTweakApply.IsEnabled = true;
            BtnTweakUndo.IsEnabled = true;
            var anyApplied = _pending.Any(p => System.Text.RegularExpressions.Regex.IsMatch(p.Status ?? "", "^(Applied|Reverted)"));
            if (!anyApplied) { _needSettingBroadcast = false; _needExplorerRestart = false; }
            if (_needSettingBroadcast)
            {
                _needSettingBroadcast = false;
                try { Optimize.SendSettingChange(); Log("Told Windows the display settings changed - theme and Explorer views apply now."); }
                catch (Exception ex) { Log("Could not broadcast the settings change: " + ex.Message + " - sign out and back in to see them."); }
            }
            if (_batchTab == "Tweak" && _needExplorerRestart)
            {
                _needExplorerRestart = false;
                try
                {
                    Log("Restarting Explorer once so the taskbar/Start/desktop changes are visible now.");
                    foreach (var p in Process.GetProcessesByName("explorer")) { try { p.Kill(); } catch { } }
                    Thread.Sleep(900);
                    if (Process.GetProcessesByName("explorer").Length == 0) Process.Start("explorer.exe");
                }
                catch (Exception ex) { Log("Explorer restart failed: " + ex.Message + " - sign out and back in to see the changes."); }
            }
            if (_batchTab != "Tweak") return;
            ShowOverlay("Batch complete", summary);
            // the free-space line under the toolbar and the Startup list both describe the machine, which just changed
            if (_pending.Any(p => (p.Id ?? "").StartsWith("startup-", StringComparison.Ordinal))) { _startupLoaded = false; _startupLoadTask = LoadStartupAsync(); }
            if (_optSubTab == "Clean") SelectOptTab("Clean");
            var _ = ConfirmAppliedRowsAsync(_pending.Where(p => !(p.Id ?? "").StartsWith("startup-", StringComparison.Ordinal)).ToList());
            // the Gaming sub-tab's evidence: a baseline was measured before the batch, so measure again and report the delta
            if (_gameBaseline != null) { var __ = FinishGamingAsync(_pending.ToList()); }
        }

        /// <summary>Confirm-AppliedRows: every Applied row with a real probe is asked again; a false answer is "could not confirm", not "failed".</summary>
        private async Task ConfirmAppliedRowsAsync(List<AppItem> rows)
        {
            var applied = rows.Where(p => (p.Status ?? "").StartsWith("Applied", StringComparison.Ordinal)).ToList();
            if (applied.Count == 0) return;
            Dictionary<string, bool?> res;
            try { res = await ProbeAsync(applied.Select(p => p.UnArgs), null); }
            catch (Exception ex) { Log("Post-apply confirmation failed: " + ex.Message); return; }
            var unconfirmed = new List<AppItem>();
            foreach (var p in applied)
            {
                bool? r;
                if (res.TryGetValue(p.UnArgs ?? "", out r) && r == false) unconfirmed.Add(p);
            }
            if (unconfirmed.Count == 0) return;
            foreach (var p in unconfirmed)
            {
                SetStatus(p, "Applied - could not confirm on this machine", "warn");
                SetRing(p, "warn");
                Log(p.Name + " -> applied, but this machine does not report it as applied afterwards.");
            }
            Log(Format.Count(unconfirmed.Count, "row", "rows") + " applied without confirmation: " + string.Join(", ", unconfirmed.Select(p => p.Name)) + " - the change was written but this build of Windows does not read it back.");
        }
    }
}
