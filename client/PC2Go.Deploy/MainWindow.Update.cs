using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Linq;
using System.Threading;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using PC2Go.Deploy.Models;
using PC2Go.Deploy.Services;

namespace PC2Go.Deploy
{
    /// <summary>
    /// The Update tab: winget's list, the Store list to look at, and Windows Update - each read by
    /// the script's own functions through the reader, each batch through the elevated worker.
    /// A scan asked for while another runs is remembered, not dropped (the queued-scan rule).
    /// </summary>
    public partial class MainWindow
    {
        private readonly ObservableCollection<AppItem> _updItems = new ObservableCollection<AppItem>();
        private readonly ObservableCollection<AppItem> _updStore = new ObservableCollection<AppItem>();
        private readonly ObservableCollection<AppItem> _updWin = new ObservableCollection<AppItem>();
        private ListCollectionView _updView, _updStoreView, _updWinView;
        private string _updSubTab = "Desk";
        private bool _updDirty = true, _updStoreDirty = true, _updWinDirty = true, _updScanning, _updStoreScanning;
        private string _updSort = "name";
        private bool _updSortDesc;
        private readonly Dictionary<string, string[]> _updWords = new Dictionary<string, string[]>
        {
            { "Desk", new[] { "", "" } }, { "Store", new[] { "", "" } }, { "Win", new[] { "", "" } },
        };
        private string _wingetPath = "";

        private void WireUpdate()
        {
            _updView = (ListCollectionView)CollectionViewSource.GetDefaultView(_updItems);
            _updStoreView = (ListCollectionView)CollectionViewSource.GetDefaultView(_updStore);
            _updWinView = (ListCollectionView)CollectionViewSource.GetDefaultView(_updWin);
            foreach (var v in new[] { _updView, _updStoreView, _updWinView })
            {
                v.GroupDescriptions.Add(new PropertyGroupDescription("Category"));
                v.Filter = UpdFilter;
            }
            ListUpd.ItemsSource = _updView;
            ListUpdStore.ItemsSource = _updStoreView;
            ListUpdWin.ItemsSource = _updWinView;
            BtnSubUpdDesk.Click += (s, e) => SelectUpdTab("Desk");
            BtnSubUpdStore.Click += (s, e) => SelectUpdTab("Store");
            BtnSubUpdWin.Click += (s, e) => SelectUpdTab("Win");
            BtnUpdSelAll.Click += (s, e) => SetUpdSelection(true);
            BtnUpdSelNone.Click += (s, e) => SetUpdSelection(false);
            BtnUpdRescan.Click += (s, e) =>
            {
                if (TestUpdateListBusy(false)) return;
                if (_updScanning) return;
                if (_updSubTab == "Win") _updWinDirty = true; else _updDirty = true;
                RequestUpdScan();
            };
            BtnUpdColName.Click += (s, e) => SetUpdSort("name");
            BtnUpdColPub.Click += (s, e) => SetUpdSort("pub");
            BtnUpdColInst.Click += (s, e) => SetUpdSort("inst");
            BtnUpdColAvail.Click += (s, e) => SetUpdSort("avail");
            BtnUpdColSrc.Click += (s, e) => SetUpdSort("src");
            BtnUpdApply.Click += (s, e) => OnUpdApplyClick();
        }

        private bool UpdFilter(object o)
        {
            if (string.IsNullOrWhiteSpace(_searchText)) return true;
            var it = o as AppItem;
            if (it == null) return true;
            var ci = StringComparison.OrdinalIgnoreCase;
            return (it.Name ?? "").IndexOf(_searchText, ci) >= 0 || (it.Publisher ?? "").IndexOf(_searchText, ci) >= 0 || (it.Category ?? "").IndexOf(_searchText, ci) >= 0;
        }

        private ObservableCollection<AppItem> UpdItemsOnScreen() { return _updSubTab == "Win" ? _updWin : _updItems; }

        private bool TestUpdateListBusy(bool quiet)
        {
            if ((_phase == "Download" || _phase == "Install") && _batchTab == "Update")
            {
                if (!quiet) ShowOverlay("Updates are running", "These rows are showing live progress from the elevated worker right now, so the list is held until the batch finishes.\n\nEverything else stays available in the meantime.");
                return true;
            }
            return false;
        }

        /// <summary>Set-UpdWords: a scan's words are kept per sub-tab and painted only when that sub-tab is on screen.</summary>
        private void SetUpdWords(string tab, string hint, string empty)
        {
            _updWords[tab] = new[] { hint ?? "", empty ?? "" };
            if (_updSubTab != tab) return;
            TxtUpdHint.Text = hint ?? "";
            EmptyUpd.Text = empty ?? "";
            EmptyUpd.Visibility = string.IsNullOrEmpty(empty) ? Visibility.Collapsed : Visibility.Visible;
        }

        private void OnUpdateTabShown() { SelectUpdTab(_updSubTab); }

        private void SelectUpdTab(string which)
        {
            _updSubTab = which;
            var store = which == "Store"; var win = which == "Win";
            BtnSubUpdDesk.Style = (Style)FindResource(store || win ? "TabIdle" : "TabActive");
            BtnSubUpdStore.Style = (Style)FindResource(store ? "TabActive" : "TabIdle");
            BtnSubUpdWin.Style = (Style)FindResource(win ? "TabActive" : "TabIdle");
            ScrollUpdDesk.Visibility = (store || win) ? Visibility.Collapsed : Visibility.Visible;
            ScrollUpdStore.Visibility = store ? Visibility.Visible : Visibility.Collapsed;
            ScrollUpdWin.Visibility = win ? Visibility.Visible : Visibility.Collapsed;
            EmptyUpd.Visibility = Visibility.Collapsed;
            foreach (var b in new[] { BtnUpdSelAll, BtnUpdSelNone, BtnUpdRescan }) b.Visibility = store ? Visibility.Collapsed : Visibility.Visible;
            TxtUpdApplyBtn.Text = store ? "Update all Store apps" : (win ? "Install Selected Updates" : "Update Selected");
            SyncUpdChrome();
            if (_tab == "Update" && !TestUpdateListBusy(true))
            {
                if (store && _updStoreDirty) LoadStoreList();
                else if ((win && _updWinDirty) || (!store && !win && _updDirty)) RequestUpdScan();
                else { var w = _updWords[which]; SetUpdWords(which, w[0], w[1]); }
            }
            UpdateDash();
            UpdateSearchCount();
        }

        /// <summary>Request-UpdScan: a scan asked for while another runs is remembered; Resume-UpdScan starts it afterwards.</summary>
        private void RequestUpdScan()
        {
            var win = _updSubTab == "Win"; var desk = _updSubTab == "Desk";
            if (!((win && _updWinDirty) || (desk && _updDirty))) return;
            if (_updScanning)
            {
                TxtLoadUpd.Text = win ? "Finishing the winget scan, then asking Windows Update..." : "Finishing the Windows Update scan, then asking winget...";
                LoadUpd.Visibility = Visibility.Visible;
                return;
            }
            if (win) LoadWinUpdates(); else LoadUpdates();
        }

        private void ResumeUpdScan()
        {
            if (_tab != "Update" || TestUpdateListBusy(true)) return;
            RequestUpdScan();
        }

        private async void LoadUpdates()
        {
            if (_updScanning) return;
            _updScanning = true;
            ListUpd.ItemsSource = null;
            _updItems.Clear();
            ScrollUpdDesk.Visibility = Visibility.Collapsed; EmptyUpd.Visibility = Visibility.Collapsed;
            TxtLoadUpd.Text = "Asking winget for available updates...";
            LoadUpd.Visibility = Visibility.Visible;
            TxtUpdHint.Text = "";
            try
            {
                var json = await _reader.RunAsync("winget", null, null, CancellationToken.None, 300);
                var load = UpdateList.Winget(json);
                _wingetPath = load.WingetPath;
                if (load.WingetPath.Length == 0)
                {
                    _updDirty = false;
                    SetUpdWords("Desk", "", "winget is not available for this account.\n\nInstall 'App Installer' from the Microsoft Store, or run Toolbox > WinGet - Reinstall, then press Rescan.");
                    Log("Update scan: winget.exe was not found for this account.");
                }
                else
                {
                    foreach (var r in load.Rows)
                    {
                        var it = r;
                        it.PropertyChanged += (s, e) => { if (e.PropertyName == "IsSelected") UpdateDash(); };
                        _updItems.Add(it);
                        if (it.IconSources.Length > 0) _icons.RequestExe(it, it.IconSources);
                        else if (!string.IsNullOrEmpty(it.StoreLocation) && !string.IsNullOrEmpty(it.StoreLogo)) _icons.RequestStore(it, it.StoreLocation, it.StoreLogo);
                    }
                    _updDirty = false;
                    var hint = UpdateList.WingetHint(load);
                    SetUpdWords("Desk", hint, _updItems.Count == 0 ? "Everything winget knows about is up to date." : "");
                    Log("Update scan: " + hint + " (winget at " + load.WingetPath + ")");
                }
            }
            catch (Exception ex)
            {
                _updDirty = false;
                Log("Update scan failed: " + ex.Message);
                SetUpdWords("Desk", "", "winget could not list updates.\n\n" + ex.Message + "\n\nPress Rescan to try again.");
            }
            finally
            {
                _updScanning = false;
                LoadUpd.Visibility = Visibility.Collapsed;
                ListUpd.ItemsSource = _updView;
                SetUpdSort(null);
                if (_updSubTab == "Desk") ScrollUpdDesk.Visibility = Visibility.Visible;
                UpdateSearchCount(); UpdateDash();
            }
            ResumeUpdScan();
        }

        private async void LoadStoreList()
        {
            if (_updStoreScanning) return;
            _updStoreScanning = true;
            ListUpdStore.ItemsSource = null;
            _updStore.Clear();
            ScrollUpdStore.Visibility = Visibility.Collapsed; EmptyUpd.Visibility = Visibility.Collapsed;
            TxtLoadUpd.Text = "Reading Microsoft Store apps...";
            LoadUpd.Visibility = Visibility.Visible;
            TxtUpdHint.Text = "";
            try
            {
                var json = await _reader.RunAsync("store", null, null, CancellationToken.None, 300);
                foreach (var r in UpdateList.StoreRows(json))
                {
                    _updStore.Add(r);
                    if (!string.IsNullOrEmpty(r.StoreLocation) && !string.IsNullOrEmpty(r.StoreLogo)) _icons.RequestStore(r, r.StoreLocation, r.StoreLogo);
                }
                _updStoreDirty = false;
                SetUpdWords("Store", Format.Count(_updStore.Count, "Store app", "Store apps") + " installed - the Store updates them as a set, so there is nothing to tick here",
                            _updStore.Count == 0 ? "No Microsoft Store apps are installed for this account." : "");
                Log("Store list: " + Format.Count(_updStore.Count, "app", "apps") + ".");
            }
            catch (Exception ex)
            {
                _updStoreDirty = false;
                Log("Store list failed: " + ex.Message);
                SetUpdWords("Store", "", "The Store apps could not be listed.\n\n" + ex.Message);
            }
            finally
            {
                _updStoreScanning = false;
                LoadUpd.Visibility = Visibility.Collapsed;
                ListUpdStore.ItemsSource = _updStoreView;
                if (_updSubTab == "Store") ScrollUpdStore.Visibility = Visibility.Visible;
                UpdateSearchCount(); UpdateDash();
            }
        }

        private async void LoadWinUpdates()
        {
            if (_updScanning) return;
            _updScanning = true;
            ListUpdWin.ItemsSource = null;
            _updWin.Clear();
            ScrollUpdWin.Visibility = Visibility.Collapsed; EmptyUpd.Visibility = Visibility.Collapsed;
            TxtLoadUpd.Text = "Asking Windows Update what is waiting...";
            LoadUpd.Visibility = Visibility.Visible;
            TxtUpdHint.Text = "";
            try
            {
                var json = await _reader.RunAsync("winupdate", null, null, CancellationToken.None, 360);
                var load = UpdateList.WindowsUpdates(json);
                foreach (var r in load.Rows)
                {
                    var it = r;
                    it.PropertyChanged += (s, e) => { if (e.PropertyName == "IsSelected") UpdateDash(); };
                    _updWin.Add(it);
                }
                _updWinDirty = false;
                var hint = UpdateList.WindowsHint(load);
                SetUpdWords("Win", hint, _updWin.Count == 0 ? "Windows Update has nothing waiting for this PC." : "");
                Log("Windows Update scan: " + hint);
            }
            catch (Exception ex)
            {
                _updWinDirty = false;
                Log("Windows Update scan failed: " + ex.Message);
                SetUpdWords("Win", "", "Windows Update could not be searched.\n\n" + ex.Message + "\n\nPress Rescan to try again.");
            }
            finally
            {
                _updScanning = false;
                LoadUpd.Visibility = Visibility.Collapsed;
                ListUpdWin.ItemsSource = _updWinView;
                SetUpdSort(null);
                if (_updSubTab == "Win") ScrollUpdWin.Visibility = Visibility.Visible;
                UpdateSearchCount(); UpdateDash();
            }
            ResumeUpdScan();
        }

        private void SetUpdSort(string how)
        {
            if (how != null)
            {
                if (_updSort == how) _updSortDesc = !_updSortDesc;
                else { _updSort = how; _updSortDesc = false; }
            }
            var dir = _updSortDesc ? ListSortDirection.Descending : ListSortDirection.Ascending;
            foreach (var v in new[] { _updView, _updStoreView, _updWinView })
            {
                v.SortDescriptions.Clear();
                switch (_updSort)
                {
                    case "pub": v.SortDescriptions.Add(new SortDescription("Publisher", dir)); break;
                    case "inst": v.SortDescriptions.Add(new SortDescription("ColInstalled", dir)); break;
                    case "avail": v.SortDescriptions.Add(new SortDescription("ColSize", dir)); break;
                    case "src": v.SortDescriptions.Add(new SortDescription("Source", dir)); break;
                    default: v.SortDescriptions.Add(new SortDescription("Name", dir)); break;
                }
            }
            SyncUpdChrome();
            _updView.Refresh(); _updStoreView.Refresh(); _updWinView.Refresh();
        }

        private void SyncUpdChrome()
        {
            var arrow = _updSortDesc ? " v" : " ^";
            var store = _updSubTab == "Store"; var win = _updSubTab == "Win";
            var cols = new[]
            {
                new { B = BtnUpdColName, K = "name", T = win ? "UPDATE" : "PROGRAM" },
                new { B = BtnUpdColPub, K = "pub", T = win ? "KB   CATEGORY" : "PUBLISHER" },
                new { B = BtnUpdColInst, K = "inst", T = store ? "VERSION" : (win ? "DOWNLOAD" : "INSTALLED") },
                new { B = BtnUpdColAvail, K = "avail", T = win ? "RESTART" : "AVAILABLE" },
                new { B = BtnUpdColSrc, K = "src", T = "SOURCE" },
            };
            foreach (var c in cols)
            {
                var on = _updSort == c.K;
                c.B.Style = (Style)FindResource(on ? "ColHeadOn" : "ColHead");
                c.B.Content = on ? c.T + arrow : c.T;
            }
            BtnUpdColAvail.Visibility = store ? Visibility.Hidden : Visibility.Visible;
        }

        private void SetUpdSelection(bool on)
        {
            if (TestUpdateListBusy(false)) return;
            foreach (var t in UpdItemsOnScreen()) t.IsSelected = on;
            UpdateDash();
        }

        private string UpdDashText()
        {
            if (_updSubTab == "Store")
                return _updStoreDirty ? "" : Format.Count(_updStore.Count, "Store app", "Store apps") + " installed - Update all Store apps asks the Store to bring every one of them current";
            if (_updSubTab == "Win")
                return _updWinDirty ? "" : _updWin.Count(i => i.IsSelected) + " of " + Format.Count(_updWin.Count, "Windows update", "Windows updates") + " selected";
            return _updDirty ? "" : _updItems.Count(i => i.IsSelected) + " of " + Format.Count(_updItems.Count, "update", "updates") + " selected";
        }

        private void UpdSearchCount(bool searching, string q)
        {
            int? nUpd = _updDirty ? (int?)null : _updView.Count;
            int? nUpdS = _updStoreDirty ? (int?)null : _updStoreView.Count;
            int? nUpdW = _updWinDirty ? (int?)null : _updWinView.Count;
            Func<string, int?, string> lbl = (b, n) => n == null ? b : b + "   " + n;
            int? total = null;
            if (searching && (nUpd != null || nUpdS != null || nUpdW != null)) total = (nUpd ?? 0) + (nUpdS ?? 0) + (nUpdW ?? 0);
            BtnTabUpdate.Content = lbl("Update", total);
            BtnSubUpdDesk.Content = lbl("Desktop apps", nUpd);
            BtnSubUpdStore.Content = lbl("Microsoft Store apps", nUpdS);
            BtnSubUpdWin.Content = lbl("Windows Update", nUpdW);
            if (_tab == "Update" && searching)
            {
                var n = _updSubTab == "Store" ? nUpdS : (_updSubTab == "Win" ? nUpdW : nUpd);
                var totalRows = _updSubTab == "Store" ? _updStore.Count : (_updSubTab == "Win" ? _updWin.Count : _updItems.Count);
                if (n == 0 && totalRows > 0) { EmptyUpd.Text = "Nothing here matches \"" + q + "\"."; EmptyUpd.Visibility = Visibility.Visible; }
                else if (totalRows > 0) EmptyUpd.Visibility = Visibility.Collapsed;
            }
        }

        // ------------------------------------------------------------------ the batch

        private void OnUpdApplyClick()
        {
            if (TestBatchBusy()) return;
            if (_updSubTab == "Store")
            {
                // one synthetic row stands in for the Store's own updater; it lives only in the batch
                var row = new AppItem
                {
                    Id = "storeupdate", Name = "Update all Store apps", Publisher = "Microsoft Store updater",
                    UnCommand = "storeupdate", UnArgs = "storeupdate", Category = "Microsoft Store",
                    IconData = Catalog.IconMap["default"][0], IconBg = "#FF7A5CFF",
                };
                ShowConfirm("Update all Store apps?",
                    "Windows will be asked to check the Microsoft Store for updates to every installed Store app and install them in the background.\n\n" +
                    "This is the same as Microsoft Store > Library > Get updates. It needs internet access, and the Store keeps working for several minutes after this batch reports done.",
                    "Continue", () => StartUpdateBatch(new List<AppItem> { row }));
                return;
            }
            if (_updSubTab == "Win")
            {
                var sel = _updWin.Where(i => i.IsSelected).ToList();
                if (sel.Count == 0) { ShowOverlay("Nothing selected", "Tick the Windows updates to install, or press Select All."); return; }
                var opt = sel.Count(i => !i.IsSilent);
                var reb = sel.Count(i => (i.ColSize ?? "").StartsWith("restart"));
                var msg = "Windows Update will download and install these " + Format.Count(sel.Count, "update", "updates") + ":\n\n" +
                          string.Join("\n", sel.Take(8).Select(i => "  - " + i.Name));
                if (sel.Count > 8) msg += "\n  - ...and " + (sel.Count - 8) + " more";
                if (opt > 0) msg += "\n\n" + opt + " of them are OPTIONAL - Windows would not have installed them on its own (drivers, previews).";
                msg += "\n\n" + (reb > 0 ? reb + " need a restart to finish. The restart is never done for you - the batch says so when it is done." : "None of them needs a restart.");
                ShowConfirm("Install Windows updates?", msg, "Continue", () => StartUpdateBatch(sel));
                return;
            }
            var selD = _updItems.Where(i => i.IsSelected).ToList();
            if (selD.Count == 0) { ShowOverlay("Nothing selected", "Tick the programs you want winget to update, or press Select All."); return; }
            var m2 = "winget will update these " + Format.Count(selD.Count, "program", "programs") + " silently:\n\n" +
                     string.Join("\n", selD.Take(8).Select(i => "  - " + i.Name + "   (" + i.Size + ")"));
            if (selD.Count > 8) m2 += "\n  - ...and " + (selD.Count - 8) + " more";
            m2 += "\n\nA running copy of a program may be closed by its installer. Each one is given up to 30 minutes.";
            ShowConfirm("Update selected programs?", m2, "Continue", () => StartUpdateBatch(selD));
        }

        /// <summary>Start-UpdateBatch: one row per winget package, or the single Store row, or Windows updates - through the same worker.</summary>
        private void StartUpdateBatch(List<AppItem> sel)
        {
            foreach (var s in sel) { SetStatus(s, "Queued", "neutral"); SetRing(s, "queued"); }
            _pending = sel.ToList();
            _batchTab = "Update";
            _runStarted = DateTime.Now;
            _dlIndex = 0; _lastLogKey.Clear();
            _hadFailures = false; _cancelRequested = false; _awaitingScan = false;
            _deepClean = false; _forceMode = false;
            foreach (var p in _pending) { p.BatchAction = null; p.Dirty = false; p.CreatedPaths = new string[0]; }
            _worker.ResetForBatch();
            ShowBatchStrip();
            if (!_worker.Start()) { AbortBatch("the administrator prompt was declined, so nothing was run", "warn"); return; }
            foreach (var s in sel)
            {
                Dictionary<string, object> e;
                if (s.UnCommand == "storeupdate")
                    e = new Dictionary<string, object> { { "id", s.Id }, { "action", "storeupdate" }, { "name", s.Name ?? "" } };
                else if (s.UnCommand == "winupdate")
                    e = new Dictionary<string, object> { { "id", s.Id }, { "action", "winupdate" }, { "updateId", s.UnArgs ?? "" }, { "name", s.Name ?? "" }, { "kb", s.DetectPath ?? "" } };
                else
                    e = new Dictionary<string, object> { { "id", s.Id }, { "action", "update" }, { "wingetId", s.UnArgs ?? "" }, { "name", s.Name ?? "" },
                                                         { "winget", _wingetPath ?? "" }, { "source", s.Source ?? "" }, { "installed", s.Version ?? "" }, { "available", s.DetectPath ?? "" } };
                _worker.Enqueue(e);
            }
            _worker.Complete();
            _phase = "Install";
            BtnUpdApply.IsEnabled = false;
            TxtNow.Text = "Updating...";
            DotNow.Fill = Res("Lift");
            TxtStatus.Text = TxtNow.Text;
            Log("Update batch: " + Format.Count(sel.Count, "item", "items") + " - " + string.Join(", ", sel.Select(x => x.UnArgs)) + ".");
            UpdateDash();
        }

        private void OnBatchEndedUpdate()
        {
            BtnUpdApply.IsEnabled = true;
            if (_batchTab != "Update") return;
            foreach (var p in _pending)
                if (p.IsSelected && ((p.Status ?? "").StartsWith("Installed") || (p.Status ?? "").StartsWith("Skipped") || (p.Status ?? "").StartsWith("Applied"))) p.IsSelected = false;
            _updDirty = true; _updStoreDirty = true; _updWinDirty = true;
            var needRestart = _pending.Count(p => ((p.StatusDetail ?? "") + (p.Status ?? "")).IndexOf("restart is needed", StringComparison.OrdinalIgnoreCase) >= 0);
            TxtUpdHint.Text = needRestart > 0 ? "Batch finished - " + Format.Count(needRestart, "update", "updates") + " will need a RESTART to finish; press Rescan afterwards"
                                              : "Batch finished - press Rescan to see what is still outdated";
            if (needRestart > 0) Log("Restart needed: " + Format.Count(needRestart, "Windows update", "Windows updates") + " will finish on the next restart.");
        }
    }
}
