using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.ComponentModel;
using System.IO;
using System.Linq;
using System.Security.Principal;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Media.Animation;
using System.Windows.Threading;
using PC2Go.Deploy.Models;
using PC2Go.Deploy.Services;

namespace PC2Go.Deploy
{
    /// <summary>
    /// The Uninstall tab: two lists read by the script's own functions in another process, the
    /// vendor uninstaller through the elevated worker, then the leftover sweep and its review
    /// sheet before anything is wiped. Force Remove skips the uninstaller and goes straight to
    /// the sweep. The words, the rules and the order of operations are the script's.
    /// </summary>
    public partial class MainWindow
    {
        private readonly ObservableCollection<AppItem> _unItems = new ObservableCollection<AppItem>();
        private readonly ObservableCollection<AppItem> _unStore = new ObservableCollection<AppItem>();
        private ListCollectionView _unView, _storeView;
        private Reader _reader;
        private Dictionary<string, object> _catalogRaw;
        private string _unSubTab = "Desktop";
        private bool _unDirty = true, _storeDirty = true, _unScanning;
        private string _unSort = "name";
        private bool _unSortDesc;
        private bool _deepClean, _forceMode;

        private readonly ObservableCollection<WipeItem> _wipeFindings = new ObservableCollection<WipeItem>();
        private ListCollectionView _wipeView;
        private bool _wipeShowWeak, _scanRunning, _scanDirty, _scanHeld, _scanCancelled, _autoUnPending;
        private CancellationTokenSource _scanCts;
        private Dictionary<string, string[]> _scanWas = new Dictionary<string, string[]>();

        private void WireUninstall()
        {
            _reader = new Reader(_cacheDir);
            _unView = (ListCollectionView)CollectionViewSource.GetDefaultView(_unItems);
            _unView.GroupDescriptions.Add(new PropertyGroupDescription("Category"));
            _unView.Filter = UnFilter;
            _storeView = (ListCollectionView)CollectionViewSource.GetDefaultView(_unStore);
            _storeView.GroupDescriptions.Add(new PropertyGroupDescription("Category"));
            _storeView.Filter = UnFilter;
            ListUn.ItemsSource = _unView;

            _wipeView = (ListCollectionView)CollectionViewSource.GetDefaultView(_wipeFindings);
            _wipeView.GroupDescriptions.Add(new PropertyGroupDescription("OwnerName"));
            _wipeView.GroupDescriptions.Add(new PropertyGroupDescription("Section"));
            _wipeView.SortDescriptions.Add(new SortDescription("SectionOrder", ListSortDirection.Ascending));
            _wipeView.SortDescriptions.Add(new SortDescription("Del", ListSortDirection.Descending));
            _wipeView.SortDescriptions.Add(new SortDescription("Weak", ListSortDirection.Ascending));
            _wipeView.SortDescriptions.Add(new SortDescription("Path", ListSortDirection.Ascending));
            _wipeView.Filter = o => { var w = o as WipeItem; return w == null || _wipeShowWeak || !w.Weak; };
            ListWipe.ItemsSource = _wipeView;

            BtnSubDesktop.Click += (s, e) => SelectUnTab("Desktop");
            BtnSubStore.Click += (s, e) => SelectUnTab("Store");
            BtnRescan.Click += (s, e) => Rescan();
            BtnColName.Click += (s, e) => SetUnSort("name");
            BtnColPub.Click += (s, e) => SetUnSort("pub");
            BtnColDate.Click += (s, e) => SetUnSort("date");
            BtnColSize.Click += (s, e) => SetUnSort("size");
            BtnUninstall.Click += (s, e) => OnUninstallClick();
            BtnForce.Click += (s, e) => OnForceClick();
            BtnWipeAll.Click += (s, e) => { foreach (var f in _wipeFindings) { if (f.Shared) continue; if (f.Weak && !_wipeShowWeak) continue; f.Del = true; } _wipeView.Refresh(); };
            BtnWipeNone.Click += (s, e) => { foreach (var f in _wipeFindings) f.Del = false; _wipeView.Refresh(); };
            BtnWipeWeak.Click += (s, e) =>
            {
                _wipeShowWeak = !_wipeShowWeak;
                // nothing may be marked for deletion while it is off screen
                if (!_wipeShowWeak) foreach (var f in _wipeFindings) if (f.Weak) f.Del = false;
                var weak = _wipeFindings.Count(f => f.Weak);
                BtnWipeWeak.Content = (_wipeShowWeak ? "Hide " : "Show ") + Format.Count(weak, "possible match", "possible matches");
                _wipeView.Refresh();
            };
            BtnWipeSkip.Click += (s, e) =>
            {
                WipeOverlay.Visibility = Visibility.Collapsed;
                Log("Leftover cleanup skipped by technician - nothing was deleted.");
                _wipeFindings.Clear();
                SetForceRemoveOutcome("cleanup was skipped, and force remove runs no uninstaller");
                ReleaseWorker();
            };
            BtnWipeGo.Click += async (s, e) => await WipeGoAsync();
        }

        // ------------------------------------------------------------------ the lists

        private bool UnFilter(object o)
        {
            if (string.IsNullOrWhiteSpace(_searchText)) return true;
            var it = o as AppItem;
            if (it == null) return true;
            var ci = StringComparison.OrdinalIgnoreCase;
            return (it.Name ?? "").IndexOf(_searchText, ci) >= 0 || (it.Publisher ?? "").IndexOf(_searchText, ci) >= 0;
        }

        private void OnUninstallTabShown() { SelectUnTab(_unSubTab); }

        private async void SelectUnTab(string which)
        {
            var store = which == "Store";
            if ((_phase == "Download" || _phase == "Install") && _batchTab != "Install" && which != _unSubTab)
            {
                ShowOverlay("Cannot switch lists yet", "A removal batch is still running and this list holds the rows it is reporting into.\n\nSwitch lists once it finishes - the list refreshes itself automatically anyway.");
                return;
            }
            if (_unScanning) return;
            _unSubTab = which;
            BtnSubDesktop.Style = (Style)FindResource(store ? "TabIdle" : "TabActive");
            BtnSubStore.Style = (Style)FindResource(store ? "TabActive" : "TabIdle");
            var dirty = store ? _storeDirty : _unDirty;
            if (!dirty)
            {
                ListUn.ItemsSource = store ? _storeView : _unView;
                UpdateSearchCount(); UpdateDash();
                return;
            }
            _unScanning = true;
            ListUn.Visibility = Visibility.Collapsed;
            LoadUn.Visibility = Visibility.Visible;
            TxtLoadUn.Text = store ? "Scanning Microsoft Store apps..." : "Scanning installed programs...";
            TxtLoadUn2.Text = store ? "Microsoft Store packages" : "Control Panel entries";
            try
            {
                if (store)
                {
                    var json = await _reader.RunAsync("store", null, null, CancellationToken.None, 300);
                    var rows = UninstallList.StoreRows(json);
                    ListUn.ItemsSource = null;
                    _unStore.Clear();
                    foreach (var r in rows)
                    {
                        var it = r;
                        it.PropertyChanged += (s, e) => { if (e.PropertyName == "IsSelected") UpdateDash(); };
                        _unStore.Add(it);
                        if (!string.IsNullOrEmpty(it.StoreLocation) && !string.IsNullOrEmpty(it.StoreLogo)) _icons.RequestStore(it, it.StoreLocation, it.StoreLogo);
                    }
                    _storeDirty = false;
                    Log("Microsoft Store apps: " + Format.Count(rows.Count, "package", "packages") + ".");
                }
                else
                {
                    var json = await _reader.RunAsync("installed", null, null, CancellationToken.None, 300);
                    var rows = UninstallList.DesktopRows(json, _catalogRaw);
                    ListUn.ItemsSource = null;
                    _unItems.Clear();
                    foreach (var r in rows)
                    {
                        var it = r;
                        it.PropertyChanged += (s, e) => { if (e.PropertyName == "IsSelected") UpdateDash(); };
                        _unItems.Add(it);
                        if (it.IconSources.Length > 0) _icons.RequestExe(it, it.IconSources);
                    }
                    _unDirty = false;
                    Log("Installed programs: " + rows.Count + " Control Panel entries.");
                }
            }
            catch (Exception ex)
            {
                Log("The scan failed: " + ex.Message);
                ShowOverlay("Scan failed", ex.Message);
            }
            finally
            {
                _unScanning = false;
                LoadUn.Visibility = Visibility.Collapsed;
                ListUn.Visibility = Visibility.Visible;
                ListUn.ItemsSource = store ? _storeView : _unView;
                SetUnSort(null);
                SyncUnCells();
                UpdateSearchCount(); UpdateDash();
            }
            if (_autoUnPending && !store) { _autoUnPending = false; HarnessUninstall(); }
        }

        private void Rescan()
        {
            if ((_phase == "Download" || _phase == "Install") && _batchTab != "Install")
            {
                ShowOverlay("Cannot rescan yet", "A removal batch is still running and this list holds the rows it is reporting into.\n\nRescan once it finishes - the list refreshes itself automatically anyway.");
                return;
            }
            if (_unSubTab == "Store") _storeDirty = true; else _unDirty = true;
            SelectUnTab(_unSubTab);
        }

        /// <summary>Set-UnSort: pressing the lit column again turns the sort round. null re-applies the current sort.</summary>
        private void SetUnSort(string how)
        {
            if (how != null)
            {
                if (_unSort == how) _unSortDesc = !_unSortDesc;
                else { _unSort = how; _unSortDesc = how == "size" || how == "date"; }
            }
            var dir = _unSortDesc ? ListSortDirection.Descending : ListSortDirection.Ascending;
            foreach (var v in new[] { _unView, _storeView })
            {
                v.SortDescriptions.Clear();
                switch (_unSort)
                {
                    case "size": v.SortDescriptions.Add(new SortDescription("SizeBytes", dir)); break;
                    case "date": v.SortDescriptions.Add(new SortDescription("Installed", dir)); break;
                    case "pub": v.SortDescriptions.Add(new SortDescription("Publisher", dir)); break;
                    default: v.SortDescriptions.Add(new SortDescription("Name", dir)); break;
                }
            }
            SyncUnChrome();
            _unView.Refresh(); _storeView.Refresh();
            UpdateDash();
        }

        private void SyncUnChrome()
        {
            var arrow = _unSortDesc ? " v" : " ^";
            var map = new[] { new { B = BtnColName, K = "name", T = "PROGRAM" }, new { B = BtnColPub, K = "pub", T = "PUBLISHER" },
                              new { B = BtnColDate, K = "date", T = "INSTALLED" }, new { B = BtnColSize, K = "size", T = "SIZE" } };
            foreach (var m in map)
            {
                var on = m.K == _unSort;
                m.B.Style = (Style)FindResource(on ? "ColHeadOn" : "ColHead");
                m.B.Content = on ? m.T + arrow : m.T;
            }
        }

        /// <summary>Sync-UnCells: the size bar is normalised over desktop and Store rows together.</summary>
        private void SyncUnCells()
        {
            var rows = _unItems.Concat(_unStore).ToList();
            if (rows.Count == 0) return;
            long max = rows.Max(r => r.SizeBytes);
            foreach (var r in rows)
            {
                var bytes = r.SizeBytes;
                r.ColSize = bytes > 0 ? Format.Size(bytes) : "no size";
                r.SizePercent = (max > 0 && bytes > 0) ? 100.0 * bytes / max : 0;
                r.RowOpacity = bytes > 0 ? 1.0 : 0.55;
                r.ColInstalled = r.Installed.HasValue ? r.Installed.Value.ToString("dd MMM yyyy") : "-";
                r.TagText = ""; r.TagVis = "Collapsed";
                if (bytes > 0 && bytes == max) { r.TagText = "largest"; r.TagVis = "Visible"; }
            }
        }

        private string UnDashText()
        {
            var store = _unSubTab == "Store";
            var shown = store ? _storeView.Count : _unView.Count;
            var sel = _unItems.Concat(_unStore).Where(i => i.IsSelected).ToList();
            long sum = sel.Sum(i => i.SizeBytes);
            var word = store ? "apps" : "programs";
            var t = shown + " " + word;
            if (sel.Count > 0)
            {
                t += "    |    " + sel.Count + " selected";
                if (sum > 0) t += "  (" + Format.Size(sum) + " reclaimed)";
            }
            return t;
        }

        /// <summary>The pill counts while searching, and the empty text for a search that matches nothing.</summary>
        private void UnSearchCount(bool searching, string q)
        {
            int? nDesk = _unDirty ? (int?)null : _unView.Count;
            int? nStore = _storeDirty ? (int?)null : _storeView.Count;
            Func<string, int?, string> lbl = (b, n) => n == null ? b : b + "   " + n;
            BtnSubDesktop.Content = lbl("Desktop programs", searching ? nDesk : null);
            BtnSubStore.Content = lbl("Microsoft Store apps", searching ? nStore : null);
            int? total = null;
            if (searching && (nDesk != null || nStore != null)) total = (nDesk ?? 0) + (nStore ?? 0);
            BtnTabUn.Content = lbl("Uninstall", total);
            EmptyUn.Visibility = Visibility.Collapsed;
            if (_tab == "Uninstall")
            {
                var store = _unSubTab == "Store";
                var n = store ? nStore : nDesk;
                if (searching && n == 0)
                {
                    var other = store ? "Desktop programs" : "Microsoft Store apps";
                    EmptyUn.Text = "No program matching \"" + q + "\" in this list.\n\nCheck the " + other + " tab - the count is shown on each tab.";
                    EmptyUn.Visibility = Visibility.Visible;
                }
            }
        }

        private void MarkListsDirty() { _unDirty = true; _storeDirty = true; }

        // ------------------------------------------------------------------ the batch

        private bool TestBatchBusy()
        {
            // a second press while the reader probes the tweak rows would start a second batch on top of the first
            if (_tweakChecking)
            {
                ShowOverlay("Still checking", "The tweak rows are being probed right now. Wait for the check to finish, then press again.");
                return true;
            }
            if (_phase != "Download" && _phase != "Install") return false;
            // named, or an account change refused itself with "apps are still downloading" - a
            // sentence about a tab the technician was not on, describing work nobody started
            var what = _batchTab == "Un" ? "A removal batch is still running."
                     : _batchTab == "Users" ? "An account change is still running."
                     : _batchTab == "Update" ? "An update batch is still running."
                     : _batchTab == "Tools" ? "A repair is still running."
                     : _batchTab == "Tweak" ? "A tweak batch is still running."
                     : _batchTab == "Migrate" ? "A backup or restore is still copying."
                     : _batchTab == "Share" ? "A sharing change is still running."
                     : _batchTab == "Fw" ? "A firewall batch is still running."
                     : "Apps are still downloading or installing.";
            ShowOverlay("Still busy", what + "\n\n" +
                "One elevated worker handles the whole queue, so a second batch cannot start until this one finishes - " +
                "that is also what keeps it to a single UAC prompt.\n\n" +
                "Your selection is kept, so you can carry on ticking and press this again when the batch ends.");
            return true;
        }

        private List<AppItem> UnSelection() { return _unItems.Concat(_unStore).Where(i => i.IsSelected).ToList(); }

        private void OnUninstallClick()
        {
            if (TestBatchBusy()) return;
            var sel = UnSelection();
            if (sel.Count == 0) { ShowOverlay("Nothing selected", "Select at least one application to uninstall."); return; }
            ShowPreflight(sel, "uninstall");
        }

        private void OnForceClick()
        {
            if (TestBatchBusy()) return;
            var sel = UnSelection();
            if (sel.Count == 0) { ShowOverlay("Nothing selected", "Select at least one application to force remove."); return; }
            ShowConfirm("Force remove without uninstalling?",
                "The vendor uninstaller will NOT be run for " + Format.Count(sel.Count, "selected item", "selected items") + ". Everything found on disk and in the registry is wiped directly.\n\n" +
                "Use this when the uninstaller is missing or broken and a normal removal has already failed. You still review the full list before anything is deleted.",
                "Continue", () => StartUninstall(sel, true));
        }

        /// <summary>Start-Uninstall. The worker is started BEFORE the Force branch: Force never queues an uninstall entry, but its wipe needs the worker.</summary>
        private void StartUninstall(List<AppItem> sel, bool force)
        {
            foreach (var s in sel) { SetStatus(s, "Queued", "neutral"); SetRing(s, "none"); }
            _pending = sel.ToList();
            _batchTab = "Un";
            _hadFailures = false; _cancelRequested = false; _awaitingScan = false; _dlIndex = 0;
            _lastLogKey.Clear();
            _runStarted = DateTime.Now;
            foreach (var s in _pending) { s.Dirty = false; s.CreatedPaths = new string[0]; s.BatchAction = null; }
            _worker.ResetForBatch();
            ShowBatchStrip();
            if (!_worker.Start()) { AbortBatch("the administrator prompt was declined, so nothing was run", "warn"); return; }
            // Deep clean is not optional: removing every trace is the reason this tool exists over
            // Control Panel. The opt-out lives in the preview, where the findings can be seen.
            _deepClean = true;
            _forceMode = force;
            BtnUninstall.IsEnabled = false;
            if (force)
            {
                foreach (var s in sel) { SetStatus(s, "Uninstalled", "ok"); SetRing(s, "ok"); }
                Log("Force remove: skipping vendor uninstallers for " + Format.Count(sel.Count, "item", "items") + ".");
                _phase = "Install";
                TxtStatus.Text = "Force removing...";
                UpdateDash();
                StartLeftoverScan();
                return;
            }
            var sid = "";
            try { using (var id = WindowsIdentity.GetCurrent()) sid = id.User.Value; } catch { }
            foreach (var s in sel)
            {
                // `silent` travels with the entry because the worker cannot work it out for itself:
                // whether a window that stays up is a fault to stop or a wizard to wait for
                _worker.Enqueue(new Dictionary<string, object>
                {
                    { "id", s.Id }, { "action", "uninstall" }, { "command", s.UnCommand ?? "" }, { "args", s.UnArgs ?? "" },
                    { "detect", s.DetectPath ?? "" }, { "location", s.CleanPaths.Length > 0 ? s.CleanPaths[0] : null },
                    { "silent", s.IsSilent }, { "userSid", sid }, { "family", s.UnFamily ?? "" },
                });
            }
            // hold the end marker: scan for leftovers and let the technician review before wiping
            _awaitingScan = true;
            _phase = "Install";
            TxtStatus.Text = "Uninstalling...";
            TxtNow.Text = "Uninstalling...";
            DotNow.Fill = Res("Lift");
            Log("Uninstall batch started: " + Format.Count(sel.Count, "application", "applications") + " via vendor uninstallers.");
            UpdateDash();
        }

        /// <summary>Once every row has reported: an uninstall batch always scans; an install batch only when something failed dirty.</summary>
        private void OnAllRowsSettled()
        {
            _awaitingScan = false;
            // a cancel or an abort already released the worker, and the wipe needs it alive
            if (_worker.EndQueued) return;
            if (_batchTab == "Install" && !_pending.Any(p => p.Dirty)) _worker.Complete();
            else StartLeftoverScan();
        }

        // ------------------------------------------------------------------ the leftover sweep

        private async void StartLeftoverScan()
        {
            if (_scanRunning) return;
            TxtNow.Text = "Scanning for leftover files, folders and registry keys...";
            DotNow.Fill = Res("Lift");
            ListWipe.ItemsSource = null;
            _wipeFindings.Clear();
            var targets = _pending.Where(p => ((p.Status ?? "").StartsWith("Uninstalled") || p.Dirty) && p.BatchAction != "uninstall").ToList();
            _scanWas.Clear();
            foreach (var p in targets)
            {
                _scanWas[p.Id] = new[] { p.Status ?? "", p.StatusFg ?? "", p.StatusDetail ?? "" };
                SetStatus(p, "Scanning for leftovers", "active"); SetRing(p, "busy");
            }
            _scanDirty = targets.Any(t => t.Dirty);
            _scanHeld = !targets.Any(t => !t.PreExisting);
            _scanCancelled = false;
            var findings = new List<WipeItem>();
            if (targets.Count > 0)
            {
                var req = new Dictionary<string, object>
                {
                    { "targets", targets.Select(t => new Dictionary<string, object> {
                        { "id", t.Id }, { "name", t.Name }, { "cleanPaths", t.CleanPaths }, { "cleanReg", t.CleanReg },
                        { "cleanTokens", t.CleanTokens }, { "cleanHosts", t.CleanHosts }, { "removers", t.Removers },
                        { "createdPaths", t.CreatedPaths ?? new string[0] }, { "preExisting", t.PreExisting } }).ToList() }
                };
                _scanRunning = true;
                _scanCts = new CancellationTokenSource();
                try
                {
                    var json = await _reader.RunAsync("leftovers", Json.Serialize(req), line => Ui(() => { TxtNow.Text = line; }), _scanCts.Token, 1800);
                    findings = ParseFindings(json);
                }
                catch (OperationCanceledException) { _scanCancelled = true; }
                catch (Exception ex) { Log("Leftover scan error: " + ex.Message); }
                finally { _scanRunning = false; }
            }
            CompleteLeftoverScan(findings, targets);
        }

        private static List<WipeItem> ParseFindings(string json)
        {
            var list = new List<WipeItem>();
            var parsed = new System.Web.Script.Serialization.JavaScriptSerializer { MaxJsonLength = int.MaxValue }.DeserializeObject((json ?? "").TrimStart('﻿'));
            foreach (var o in (parsed as object[]) ?? new object[0])
            {
                var d = o as Dictionary<string, object>;
                if (d == null) continue;
                list.Add(new WipeItem
                {
                    OwnerId = Json.Str(d, "OwnerId"), OwnerName = Json.Str(d, "OwnerName"), Kind = Json.Str(d, "Kind"), Type = Json.Str(d, "Type"),
                    Path = Json.Str(d, "Path"), Name = Json.Str(d, "Name"), SizeBytes = Json.Long(d, "SizeBytes"), SizeText = Json.Str(d, "SizeText"),
                    Del = Json.Bool(d, "Del"), Args = Json.Str(d, "Args"), Sha256 = Json.Str(d, "Sha256"), Weak = Json.Bool(d, "Weak"),
                    Shared = Json.Bool(d, "Shared"), IsDir = Json.Bool(d, "IsDir"),
                });
            }
            return list;
        }

        private void CompleteLeftoverScan(List<WipeItem> findings, List<AppItem> targets)
        {
            // a failed install comes out of the scan reading exactly as it went in - red, with its reason
            foreach (var p in targets)
            {
                string[] was;
                if (p.Dirty && _scanWas.TryGetValue(p.Id, out was))
                {
                    p.StatusFg = was[1]; p.StatusDetail = was[2]; p.Status = was[0]; SetRing(p, "fail");
                }
                else { SetStatus(p, "Uninstalled", "ok"); SetRing(p, "ok"); }
            }
            if (findings.Count == 0)
            {
                Log(_scanCancelled ? "Leftover scan stopped before anything was found."
                    : targets.Count == 0 ? "Nothing to scan - no product was removed in this batch."
                    : "Leftover scan: nothing found - the machine is already clean.");
                SetForceRemoveOutcome("force remove found no traces to delete, and no uninstaller was run");
                ReleaseWorker();
                return;
            }
            foreach (var f in findings) _wipeFindings.Add(f);
            ListWipe.ItemsSource = _wipeView;
            var weak = findings.Count(f => f.Weak);
            _wipeShowWeak = weak == findings.Count;   // if everything is weak, show everything
            BtnWipeWeak.Content = (_wipeShowWeak ? "Hide " : "Show ") + Format.Count(weak, "possible match", "possible matches");
            BtnWipeWeak.Visibility = weak == 0 ? Visibility.Collapsed : Visibility.Visible;
            _wipeView.Refresh();
            var shown = findings.Where(f => _wipeShowWeak || !f.Weak).ToList();
            long bytes = shown.Sum(f => f.SizeBytes);
            var pre = shown.Count(f => f.Del);
            var held = _scanDirty && _scanHeld;
            string tail;
            if (pre == shown.Count) tail = "All " + pre + " are known app data and checked.";
            else if (pre > 0) tail = pre + " are known app data and checked; the other " + (shown.Count - pre) + " matched by name only.";
            else if (held) tail = "Nothing is pre-checked: the product was on this machine before this batch, so what is listed may be its working copy rather than debris. Tick what should go.";
            else tail = "Nothing is pre-checked - every item here matched by name only. Tick what should go.";
            if (weak > 0 && !_wipeShowWeak) tail += " " + Format.Count(weak, "name-only guess", "name-only guesses") + " behind the Show button.";
            if (_scanCancelled) tail += " The scan was stopped early, so this list may be incomplete.";
            tail += " Review the list, then click Wipe checked to finish.";
            var head = _scanDirty
                ? Format.Count(shown.Count, "item", "items") + " left on disk by the failed installs, totalling " + Format.Size(bytes) + ". "
                : Format.Count(shown.Count, "leftover item", "leftover items") + " survived the uninstaller, totalling " + Format.Size(bytes) + ". ";
            TxtWipeSub.Text = head + tail;
            TxtNow.Text = "Leftovers found - awaiting review";
            DotNow.Fill = Brush("#FFFBBF24");
            WipeOverlay.Opacity = 0;
            WipeOverlay.Visibility = Visibility.Visible;
            WipeOverlay.BeginAnimation(OpacityProperty, new DoubleAnimation(0, 1, new Duration(TimeSpan.FromMilliseconds(220))));
            if (App.Opts.AutoWipe)
            {
                Log("Harness: wiping what the sweep pre-checked.");
                Dispatcher.BeginInvoke(new Action(() => BtnWipeGo.RaiseEvent(new RoutedEventArgs(System.Windows.Controls.Primitives.ButtonBase.ClickEvent))), DispatcherPriority.Background);
            }
        }

        private async Task WipeGoAsync()
        {
            WipeOverlay.Visibility = Visibility.Collapsed;
            // the batch may have ended under the sheet: nothing is deleted on a worker that has gone
            if (_phase != "Install" || _worker.EndQueued || !_worker.Started)
            {
                Log("The batch had already ended - nothing was deleted. Rescan and remove again to clean up.");
                _wipeFindings.Clear();
                return;
            }
            var chosen = _wipeFindings.Where(f => f.Del).ToList();
            if (chosen.Count == 0)
            {
                Log("No leftover items were checked - nothing deleted.");
                _wipeFindings.Clear();
                SetForceRemoveOutcome("nothing was ticked for removal, and force remove runs no uninstaller");
                ReleaseWorker();
                return;
            }
            // a removal tool that is a URL is fetched now, verified by the worker before it runs
            foreach (var c in chosen.Where(f => f.Type == "run" && System.Text.RegularExpressions.Regex.IsMatch(f.Path ?? "", "^(?i)(https?|file)://")).ToList())
            {
                var fn = Catalog.FileNameOf(c.Path);
                if (string.IsNullOrEmpty(fn)) fn = "remover-" + Guid.NewGuid().ToString("N").Substring(0, 8) + ".exe";
                var dir = Path.Combine(_cacheDir, "removers");
                Directory.CreateDirectory(dir);
                var local = Path.Combine(dir, fn);
                Log("Fetching removal tool " + fn + "...");
                var ok = false; var why = "";
                try
                {
                    if (c.Path.StartsWith("file://", StringComparison.OrdinalIgnoreCase)) { File.Copy(new Uri(c.Path).LocalPath, local, true); ok = true; }
                    else ok = await _edge.GetFileAsync(c.Path, local, 120, CancellationToken.None);
                    if (!ok) why = "the download failed";
                }
                catch (Exception ex) { why = ex.Message; }
                if (ok) c.LocalFile = local;
                else { Log("Could not fetch removal tool " + fn + " - " + why + ". It was skipped; everything else still runs."); chosen.Remove(c); }
            }
            if (chosen.Count == 0)
            {
                Log("Nothing runnable was left after fetching - no cleanup was performed.");
                _wipeFindings.Clear();
                ReleaseWorker();
                return;
            }
            // force mode: a product nothing was ticked for had nothing done to it
            if (_forceMode)
            {
                var owners = new HashSet<string>(chosen.Select(c => c.OwnerId), StringComparer.Ordinal);
                foreach (var p in _pending)
                    if (!owners.Contains(p.Id) && (p.Status ?? "").StartsWith("Uninstalled"))
                    { SetStatus(p, "Skipped: nothing was ticked for this product, and force remove runs no uninstaller", "warn"); SetRing(p, "warn"); }
            }
            var sid = "";
            try { using (var id = WindowsIdentity.GetCurrent()) sid = id.User.Value; } catch { }
            long bytes = chosen.Sum(c => c.SizeBytes);
            foreach (var grp in chosen.GroupBy(c => c.OwnerId))
            {
                var item = _pending.FirstOrDefault(p => p.Id == grp.Key);
                if (item != null) { SetStatus(item, "Cleaning leftovers", "active"); SetRing(item, "busy"); }
                var targets = new List<Dictionary<string, object>>();
                foreach (var c in grp)
                {
                    var t = new Dictionary<string, object> { { "type", c.Type }, { "path", c.Path }, { "name", c.Name ?? "" } };
                    if (c.Type == "run")
                    {
                        t["args"] = c.Args ?? "";
                        if (!string.IsNullOrEmpty(c.LocalFile)) { t["file"] = c.LocalFile; t["sha256"] = c.Sha256 ?? ""; }
                    }
                    targets.Add(t);
                }
                _worker.Enqueue(new Dictionary<string, object> { { "id", grp.Key }, { "action", "wipe" }, { "userSid", sid }, { "targets", targets } });
            }
            Log("Wiping " + Format.Count(chosen.Count, "leftover item", "leftover items") + ", " + Format.Size(bytes) + " - registry keys and folders included.");
            TxtNow.Text = "Wiping leftovers...";
            DotNow.Fill = Res("Lift");
            _wipeFindings.Clear();
            _worker.Complete();
        }

        private void ReleaseWorker()
        {
            if (_worker.Started) _worker.Complete(); else FinishBatch();
        }

        private void SetForceRemoveOutcome(string why)
        {
            if (!_forceMode) return;
            foreach (var p in _pending)
                if ((p.Status ?? "").StartsWith("Uninstalled")) { SetStatus(p, "Skipped: " + why, "warn"); SetRing(p, "warn"); }
        }

        /// <summary>Cancel during the review or the scan is its own thing: nothing is deleted, and the worker is released.</summary>
        private bool CancelUninstallSpecial()
        {
            if (WipeOverlay.Visibility == Visibility.Visible)
            {
                WipeOverlay.Visibility = Visibility.Collapsed;
                Log("Leftover cleanup cancelled by technician - nothing was deleted.");
                _wipeFindings.Clear();
                SetForceRemoveOutcome("cleanup was cancelled, and force remove runs no uninstaller");
                ReleaseWorker();
                return true;
            }
            if (_scanRunning)
            {
                try { if (_scanCts != null) _scanCts.Cancel(); } catch { }
                TxtNow.Text = "Stopping the leftover scan - showing what was found so far...";
                Log("Leftover scan stopped by technician - the preview shows what was found up to that point.");
                return true;
            }
            return false;
        }

        private void OnBatchEndedUninstall()
        {
            if (_batchTab == "Un")
                foreach (var p in _pending)
                    if (p.IsSelected && ((p.Status ?? "").StartsWith("Uninstalled") || (p.Status ?? "").StartsWith("Cleaned"))) p.IsSelected = false;
            _deepClean = false; _forceMode = false;
            BtnUninstall.IsEnabled = true;
            // machine state changed: both inventories re-scan next time their list is opened
            MarkListsDirty();
        }

        // ------------------------------------------------------------------ harness

        private void HarnessUninstall()
        {
            var want = App.Opts.AutoUninstall;
            var sel = _unItems.Concat(_unStore).Where(i => want.Contains(i.Name, StringComparer.OrdinalIgnoreCase) || want.Contains(i.Id, StringComparer.OrdinalIgnoreCase)).ToList();
            foreach (var i in sel) i.IsSelected = true;
            Log("Harness: auto-" + (App.Opts.AutoForce ? "force-removing " : "uninstalling ") + string.Join(", ", sel.Select(i => i.Name)) + (sel.Count == 0 ? "(nothing matched)" : "") + ".");
            if (sel.Count == 0) { if (App.Opts.AutoClose) { _forceClose = true; Close(); } return; }
            if (App.Opts.AutoForce) { StartUninstall(sel, true); return; }
            ShowPreflight(sel, "uninstall");
            if (!BtnPfGo.IsEnabled)
            {
                Log("Harness: nothing to uninstall - " + (PfCommitItems().Count == 0 ? "everything selected is already gone" : "the sheet refused"));
                HidePreflight();
                if (App.Opts.AutoClose) { _forceClose = true; Dispatcher.BeginInvoke(new Action(Close), DispatcherPriority.Background); }
                return;
            }
            BtnPfGo.RaiseEvent(new RoutedEventArgs(System.Windows.Controls.Primitives.ButtonBase.ClickEvent));
        }
    }
}
