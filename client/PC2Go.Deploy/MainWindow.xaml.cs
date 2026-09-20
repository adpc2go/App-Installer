using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.ComponentModel;
using System.IO;
using System.Linq;
using System.Security.Principal;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Documents;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using PC2Go.Deploy.Models;
using PC2Go.Deploy.Services;

namespace PC2Go.Deploy
{
    /// <summary>
    /// The window. Every read that could take longer than a frame is awaited, never pumped: the
    /// catalog fetch, the icon pump, the downloads. The 400 ms timer only reads the worker's
    /// status file and recounts the strip, which is what the script's timer does too.
    /// </summary>
    public partial class MainWindow : Window
    {
        private readonly string _cacheDir, _manifestCache;
        private readonly ObservableCollection<AppItem> _items = new ObservableCollection<AppItem>();
        private readonly ObservableCollection<AppItem> _batchRows = new ObservableCollection<AppItem>();
        private readonly ObservableCollection<PreflightRow> _pfRows = new ObservableCollection<PreflightRow>();
        private ListCollectionView _view;
        private readonly EdgeClient _edge;
        private readonly IconPump _icons;
        private readonly WorkerHost _worker;
        private readonly SessionLog _log;
        private readonly DispatcherTimer _timer, _searchTimer;

        private string _phase = "Idle";      // Idle | Download | Install | Done
        private string _batchTab = "";
        private string _tab = "Install";
        private string _searchText = "";
        private List<AppItem> _pending = new List<AppItem>();
        private readonly List<AppItem> _deferred = new List<AppItem>();
        private bool _batchLive, _batchFolded, _cancelRequested, _hadFailures, _awaitingScan, _catalogLoaded, _busy, _forceClose;
        private int _dlIndex;
        private CancellationTokenSource _dlCts;
        private bool _resumeOffered;
        private readonly HashSet<string> _urlRefreshed = new HashSet<string>(StringComparer.Ordinal);
        private readonly Dictionary<string, string> _lastLogKey = new Dictionary<string, string>(StringComparer.Ordinal);
        private DateTime _runStarted;

        private List<AppItem> _pfItems = new List<AppItem>();
        private readonly HashSet<string> _pfHave = new HashSet<string>(StringComparer.Ordinal);
        private readonly List<KeyValuePair<AppItem, string>> _pfMissing = new List<KeyValuePair<AppItem, string>>();
        private Action _confirmAction;

        private Paragraph _logPara;
        private int _logLines;
        private const int LogMax = 500;
        private static readonly Dictionary<string, string> LogPalette = new Dictionary<string, string>
        {
            { "time", "#FF6E6E7A" }, { "default", "#FFC9C9D2" }, { "ok", "#FF34D399" }, { "fail", "#FFF87171" }, { "warn", "#FFFBBF24" },
        };

        public MainWindow()
        {
            InitializeComponent();
            _cacheDir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "PC2GoDeploy");
            try { Directory.CreateDirectory(_cacheDir); } catch { }
            _manifestCache = Path.Combine(_cacheDir, "apps.json");

            _log = new SessionLog(App.Opts.BaseUrl, App.Elevated);
            _log.Line += OnLogLine;
            _edge = new EdgeClient(App.Opts.BaseUrl, AccessCode.Read());
            _icons = new IconPump(_edge, _cacheDir, (it, img) => Dispatcher.BeginInvoke(new Action(() => SetAppIcon(it, img))));
            _worker = new WorkerHost(_cacheDir);

            _view = (ListCollectionView)CollectionViewSource.GetDefaultView(_items);
            _view.GroupDescriptions.Add(new PropertyGroupDescription("Category"));
            _view.Filter = FilterRow;
            ListApps.ItemsSource = _view;
            ListBatch.ItemsSource = _batchRows;
            ListPf.ItemsSource = _pfRows;

            Wire();
            WireUninstall();
            WireUpdate();
            WireAccounts();
            WireToolbox();
            WireBackup();
            WireOptimize();
            WireFirewall();

            _timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(400) };
            _timer.Tick += (s, e) => Tick();
            _timer.Start();
            _searchTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(220) };
            _searchTimer.Tick += (s, e) => { _searchTimer.Stop(); ApplySearch(); };

            Loaded += (s, e) => Entrance();
            ContentRendered += async (s, e) =>
            {
                if (_catalogLoaded) return;
                _catalogLoaded = true;
                await LoadCatalogAsync();
            };
            Closing += OnClosing;
            Log("Session started. Elevated: " + (App.Elevated ? "yes" : "no") + ". Server: " + App.Opts.BaseUrl);
        }

        // ------------------------------------------------------------------ wiring

        private void Wire()
        {
            BtnWinClose.Click += (s, e) => Close();
            BtnMin.Click += (s, e) => WindowState = WindowState.Minimized;
            TitleBar.MouseLeftButtonDown += (s, e) => { try { DragMove(); } catch { } };

            foreach (var b in new[] { BtnTabUpdate, BtnTabInstall, BtnTabUn, BtnTabTweak, BtnTabUsers, BtnTabMigrate, BtnTabFw, BtnTabTools, BtnTabLog })
            {
                var btn = b;
                btn.Click += (s, e) => SelectTab((string)btn.Tag);
            }

            TxtSearch.TextChanged += (s, e) =>
            {
                var has = TxtSearch.Text.Length > 0;
                HintSearch.Visibility = has ? Visibility.Collapsed : Visibility.Visible;
                BtnSearchClear.Visibility = has ? Visibility.Visible : Visibility.Collapsed;
                _searchTimer.Stop(); _searchTimer.Start();
            };
            TxtSearch.KeyDown += (s, e) => { if (e.Key == Key.Escape) TxtSearch.Text = ""; };
            BtnSearchClear.Click += (s, e) => { TxtSearch.Text = ""; TxtSearch.Focus(); };

            BtnInstall.Click += (s, e) => OnInstallClick();
            BtnRefresh.Click += async (s, e) => { if (_phase == "Idle" || _phase == "Done") await LoadCatalogAsync(); };
            BtnCancel.Click += (s, e) => OnCancel();

            BatchHead.MouseLeftButtonDown += (s, e) => { _batchFolded = !_batchFolded; SyncBatchStrip(); };
            BtnBatchFold.Click += (s, e) => { _batchFolded = !_batchFolded; SyncBatchStrip(); };
            BtnBatchClose.Click += (s, e) => ClearStrip();

            BtnPfCancel.Click += (s, e) => HidePreflight();
            BtnPfGo.Click += (s, e) =>
            {
                var commit = PfCommitItems();
                if (_pfAction == "uninstall")
                {
                    foreach (var h in _pfItems.Where(p => _pfHave.Contains(p.Id) && !commit.Contains(p)))
                    {
                        h.IsSelected = false;
                        SetStatus(h, "Already removed", "ok"); SetRing(h, "ok");
                        Log(h.Name + ": no longer on this machine - skipped (tick 'Run the uninstaller anyway' on the sheet to force it).");
                    }
                }
                HidePreflight();
                if (commit.Count == 0) return;
                if (_pfAction == "install") StartBatch(commit); else StartUninstall(commit, false);
            };
            ChkPfHave.Checked += (s, e) => SyncPreflight();
            ChkPfHave.Unchecked += (s, e) => SyncPreflight();
            BtnPfAddDep.Click += (s, e) => PfAddMissing();

            BtnOverlayOk.Click += (s, e) => { Overlay.Visibility = Visibility.Collapsed; var a = _confirmAction; _confirmAction = null; if (a != null) a(); };
            BtnOverlayCancel.Click += (s, e) => { Overlay.Visibility = Visibility.Collapsed; _confirmAction = null; };

            BtnCopyLog.Click += (s, e) => { try { Clipboard.SetText(LogText()); TxtStatus.Text = "Log copied."; } catch { } };
            BtnSaveLog.Click += (s, e) => SaveLog();
        }

        private void Entrance()
        {
            var ease = new CubicEase { EasingMode = EasingMode.EaseOut };
            var d = new Duration(TimeSpan.FromMilliseconds(380));
            BeginAnimation(OpacityProperty, new DoubleAnimation(0, 1, d) { EasingFunction = ease });
            RootScale.BeginAnimation(ScaleTransform.ScaleXProperty, new DoubleAnimation(0.97, 1, d) { EasingFunction = ease });
            RootScale.BeginAnimation(ScaleTransform.ScaleYProperty, new DoubleAnimation(0.97, 1, d) { EasingFunction = ease });
        }

        private Brush Brush(string hex)
        {
            try { return new SolidColorBrush((Color)ColorConverter.ConvertFromString(hex)); } catch { return Brushes.Gray; }
        }

        private Brush Res(string key) { return (Brush)FindResource(key); }

        // ------------------------------------------------------------------ catalog

        private async Task LoadCatalogAsync()
        {
            TxtCatalogInfo.Text = "Connecting...";
            DotLive.Fill = Res("Dim");
            string text = null, fetchErr = null;
            var live = false;
            try
            {
                text = await _edge.GetCatalogAsync(CancellationToken.None);
                live = true;
            }
            catch (EdgeAccessException ex)
            {
                TxtCatalogInfo.Text = "Access code required";
                DotLive.Fill = Brush("#FFF87171");
                Log("The catalog refused this session's access code (" + ex.Message + ").");
                TxtStatus.Text = "Access code required";
                ShowOverlay("No application catalog",
                    "The server refused the access code (or none was given).\n\n" +
                    "Close this window and start again from the usual line:\n  irm https://apps.pc2go.ca/go | iex\n\n" +
                    "It will ask for the code. If the code was changed recently, get the current one.");
                return;
            }
            catch (Exception ex) { fetchErr = ex.Message; }

            if (live)
            {
                try { File.WriteAllText(_manifestCache, text, new UTF8Encoding(false)); } catch { }
                TxtCatalogInfo.Text = "Live catalog";
                DotLive.Fill = Brush("#FF34D399");
                // the code is not ours to leave on a client's disk
                AccessCode.Clear();
            }
            else
            {
                string cached = null;
                try
                {
                    if (File.Exists(_manifestCache))
                    {
                        cached = File.ReadAllText(_manifestCache, Encoding.UTF8);
                        var probe = Json.ParseObject(cached);
                        if (probe == null || Json.Arr(probe, "apps").Length == 0) { cached = null; try { File.Delete(_manifestCache); } catch { } }
                    }
                }
                catch { cached = null; }
                if (cached != null)
                {
                    text = cached;
                    TxtCatalogInfo.Text = "Offline copy";
                    DotLive.Fill = Brush("#FFFBBF24");
                    Log("Server unreachable - using cached catalog. (" + fetchErr + ")");
                }
                else
                {
                    var noServer = App.Opts.BaseUrl.IndexOf("apps.example.com", StringComparison.OrdinalIgnoreCase) >= 0 ||
                                   App.Opts.BaseUrl.IndexOf("YOUR-SERVER", StringComparison.OrdinalIgnoreCase) >= 0;
                    var badge = noServer ? "No server configured" : "No connection";
                    TxtCatalogInfo.Text = badge;
                    DotLive.Fill = Brush("#FFF87171");
                    TxtStatus.Text = badge;
                    Log("Could not load the catalog from " + App.Opts.BaseUrl + " (" + fetchErr + ").");
                    ShowOverlay("No application catalog", noServer
                        ? "This copy was started without a server address. Start it from the usual line:\n  irm https://apps.pc2go.ca/go | iex"
                        : "Could not reach " + App.Opts.BaseUrl + ".\n\nCheck this machine's internet connection, then press Refresh.\n\n(" + fetchErr + ")");
                    return;
                }
            }

            CatalogLoad load;
            try { load = Catalog.Parse(text); }
            catch (Exception ex)
            {
                TxtCatalogInfo.Text = "Catalog unreadable";
                DotLive.Fill = Brush("#FFF87171");
                Log("The catalog could not be read: " + ex.Message);
                ShowOverlay("No application catalog", "The catalog was fetched but could not be read: " + ex.Message);
                return;
            }

            _catalogRaw = load.Raw;
            _items.Clear();
            foreach (var item in load.Items)
            {
                var it = item;
                it.PropertyChanged += (s, e) => { if (e.PropertyName == "IsSelected") UpdateDash(); };
                if (!string.IsNullOrEmpty(it.IconUrl))
                {
                    var img = _icons.Cached(it);
                    if (img != null) SetAppIcon(it, img); else _icons.Request(it);
                }
                _items.Add(it);
            }
            Log("Catalog loaded: " + _items.Count + " applications.");
            foreach (var sk in load.Skipped) Log("Catalog entry skipped - " + sk);
            if (load.Skipped.Count > 0 && _items.Count == 0)
            {
                TxtCatalogInfo.Text = "Catalog has no usable entries";
                DotLive.Fill = Brush("#FFF87171");
            }
            UpdateDash();
            UpdateSearchCount();

            if (App.Opts.AutoInstall.Length > 0 && (_phase == "Idle" || _phase == "Done"))
            {
                var sel = _items.Where(i => App.Opts.AutoInstall.Contains(i.Id, StringComparer.OrdinalIgnoreCase)).ToList();
                foreach (var i in sel) i.IsSelected = true;
                Log("Harness: auto-installing " + string.Join(", ", sel.Select(i => i.Id)) + ".");
                if (sel.Count == 0) { if (App.Opts.AutoClose) { _forceClose = true; Close(); } return; }
                ShowPreflight(sel, "install");
                if (!BtnPfGo.IsEnabled)
                {
                    // the sheet refused: already installed, or a base is missing - the log says which
                    Log("Harness: nothing to install - " + (PfCommitItems().Count == 0 ? "everything selected is already on this machine" : TxtPfDepNote.Text));
                    HidePreflight();
                    if (App.Opts.AutoClose) { _forceClose = true; Dispatcher.BeginInvoke(new Action(Close), DispatcherPriority.Background); }
                    return;
                }
                // the same press a technician makes, through the same handler
                BtnPfGo.RaiseEvent(new RoutedEventArgs(System.Windows.Controls.Primitives.ButtonBase.ClickEvent));
            }
            else if (App.Opts.AutoUninstall.Length > 0 && (_phase == "Idle" || _phase == "Done"))
            {
                _autoUnPending = true;
                SelectTab("Uninstall");
            }
            else if (!string.IsNullOrEmpty(App.Opts.StartTab)) SelectTab(App.Opts.StartTab);
            else if (_phase == "Idle" || _phase == "Done") OfferResumeDownloads();
        }

        /// <summary>
        /// Offer-ResumeDownloads: downloads that stopped part-way - a reboot, a crash, a closed window -
        /// leave a pre-allocated .part beside a .parts journal in the cache. Offered once, at launch,
        /// with the size already on disk named; nothing already downloaded is fetched again.
        /// </summary>
        private void OfferResumeDownloads()
        {
            if (_resumeOffered) return;
            _resumeOffered = true;
            var pending = new List<AppItem>();
            long bytes = 0;
            foreach (var it in _items)
            {
                try
                {
                    if (string.IsNullOrEmpty(it.Id) || string.IsNullOrEmpty(it.FileName)) continue;
                    // NOT CachePath: that creates the folder, and this runs for every row at start
                    var dest = Path.Combine(_cacheDir, "files", Catalog.SafeId(it.Id), it.FileName);
                    if (File.Exists(dest) || !File.Exists(dest + ".part") || !File.Exists(dest + ".parts")) continue;
                    var j = SegmentedDownloader.ReadJournal(dest + ".parts");
                    var done = SegmentedDownloader.JournalDone(j);
                    if (done > 0 && Json.Long(j, "total") == it.SizeBytes) { pending.Add(it); bytes += done; }
                }
                catch { }
            }
            if (pending.Count == 0) return;
            var names = string.Join(", ", pending.Select(p => p.Name));
            Log("Interrupted downloads found in the cache: " + names + " (" + Format.Size(bytes) + " already here).");
            ShowConfirm("Resume interrupted downloads?",
                Format.Count(pending.Count, "download", "downloads") + " stopped part-way last time - " + names + " - with " + Format.Size(bytes) + " already on this machine.\n\n" +
                "Resume now? Nothing already downloaded is fetched again.",
                "Continue", () =>
                {
                    foreach (var p in pending) p.IsSelected = true;
                    ShowPreflight(pending, "install");
                });
        }

        private void SetAppIcon(AppItem item, BitmapImage img)
        {
            item.IconImage = img;
            item.IconBg = "#00000000";
            item.GlyphVis = "Collapsed";
            item.TextVis = "Collapsed";
            item.ImgVis = "Visible";
        }

        // ------------------------------------------------------------------ search and tabs

        private bool FilterRow(object o)
        {
            if (string.IsNullOrWhiteSpace(_searchText)) return true;
            var it = o as AppItem;
            if (it == null) return true;
            var q = _searchText;
            var ci = StringComparison.OrdinalIgnoreCase;
            return (it.Name ?? "").IndexOf(q, ci) >= 0 || (it.Publisher ?? "").IndexOf(q, ci) >= 0 || (it.Category ?? "").IndexOf(q, ci) >= 0;
        }

        private void ApplySearch()
        {
            _searchText = TxtSearch.Text;
            _view.Refresh();
            _unView.Refresh(); _storeView.Refresh();
            _updView.Refresh(); _updStoreView.Refresh(); _updWinView.Refresh();
            // Startup and Gaming carry the same filter and were never refreshed: a word left in the
            // search box when either list first loaded filtered it on the way in and nothing ever
            // brought the rest back, so the sub-tab stayed short for the whole session.
            _fixView.Refresh(); _tweakView.Refresh(); _cleanView.Refresh(); _startupView.Refresh(); _gameView.Refresh();
            _fwView.Refresh(); _fwOpenView.Refresh();
            UpdateSearchCount();
        }

        private void UpdateSearchCount()
        {
            var q = _searchText;
            var searching = !string.IsNullOrWhiteSpace(q);
            var n = _view.Count;
            BtnTabInstall.Content = searching ? "Install   " + n : "Install";
            EmptyInstall.Visibility = Visibility.Collapsed;
            if (searching && _tab == "Install" && n == 0)
            {
                EmptyInstall.Text = "No app matching \"" + q + "\" in the catalog.\n\nTry the Uninstall tab to see if it is already installed.";
                EmptyInstall.Visibility = Visibility.Visible;
            }
            UnSearchCount(searching, q);
            UpdSearchCount(searching, q);
            OptSearchCount(searching, q);
            FwSearchCount(searching, q);
            if (_phase != "Idle" && _phase != "Done") return;
            if (searching && _tab == "Install") TxtStatus.Text = n + " of " + _items.Count + " apps match \"" + q + "\"";
            else UpdateDash();
        }

        private void SelectTab(string name)
        {
            _tab = name;
            foreach (var b in new[] { BtnTabUpdate, BtnTabInstall, BtnTabUn, BtnTabTweak, BtnTabUsers, BtnTabMigrate, BtnTabFw, BtnTabTools, BtnTabLog })
                b.Style = (Style)FindResource(((string)b.Tag) == name ? "TabActive" : "TabIdle");
            PanelInstall.Visibility = name == "Install" ? Visibility.Visible : Visibility.Collapsed;
            PanelUn.Visibility = name == "Uninstall" ? Visibility.Visible : Visibility.Collapsed;
            PanelUpdate.Visibility = name == "Update" ? Visibility.Visible : Visibility.Collapsed;
            PanelAccounts.Visibility = name == "User Accounts" ? Visibility.Visible : Visibility.Collapsed;
            PanelTools.Visibility = name == "Toolbox" ? Visibility.Visible : Visibility.Collapsed;
            PanelMigrate.Visibility = name == "Data Backup" ? Visibility.Visible : Visibility.Collapsed;
            PanelTweak.Visibility = name == "Optimize" ? Visibility.Visible : Visibility.Collapsed;
            PanelFw.Visibility = name == "Firewall" ? Visibility.Visible : Visibility.Collapsed;
            PanelLog.Visibility = name == "Activity Log" ? Visibility.Visible : Visibility.Collapsed;
            var soon = name != "Install" && name != "Activity Log" && name != "Uninstall" && name != "Update" && name != "User Accounts" && name != "Toolbox" && name != "Data Backup" && name != "Optimize" && name != "Firewall";
            PanelSoon.Visibility = soon ? Visibility.Visible : Visibility.Collapsed;
            if (soon)
            {
                TxtSoonTitle.Text = name;
                TxtSoonMsg.Text = "This part of the tool is still in the script client. Close this window, run the usual line again and open " + name +
                                  " there. Each tab moves into this build in turn; Install came first because it is what a remote visit is for.";
            }
            BtnInstall.Visibility = name == "Install" ? Visibility.Visible : Visibility.Collapsed;
            BtnRefresh.Visibility = name == "Install" ? Visibility.Visible : Visibility.Collapsed;
            BtnUninstall.Visibility = name == "Uninstall" ? Visibility.Visible : Visibility.Collapsed;
            BtnForce.Visibility = name == "Uninstall" ? Visibility.Visible : Visibility.Collapsed;
            BtnUpdApply.Visibility = name == "Update" ? Visibility.Visible : Visibility.Collapsed;
            BtnRunFix.Visibility = name == "Toolbox" ? Visibility.Visible : Visibility.Collapsed;
            BtnMigrate.Visibility = name == "Data Backup" ? Visibility.Visible : Visibility.Collapsed;
            BtnFwBlock.Visibility = name == "Firewall" ? Visibility.Visible : Visibility.Collapsed;
            BtnFwUnblock.Visibility = name == "Firewall" ? Visibility.Visible : Visibility.Collapsed;
            BtnFwRemoveAll.Visibility = name == "Firewall" ? Visibility.Visible : Visibility.Collapsed;
            if (name != "Optimize") { BtnTweakApply.Visibility = Visibility.Collapsed; BtnTweakUndo.Visibility = Visibility.Collapsed; }
            BtnCopyLog.Visibility = name == "Activity Log" ? Visibility.Visible : Visibility.Collapsed;
            BtnSaveLog.Visibility = name == "Activity Log" ? Visibility.Visible : Visibility.Collapsed;
            UpdateDash();
            UpdateSearchCount();
            if (name == "Uninstall") OnUninstallTabShown();
            if (name == "Update") OnUpdateTabShown();
            if (name == "User Accounts") OnAccountsTabShown();
            if (name == "Toolbox") OnToolsTabShown();
            if (name == "Data Backup") { var _ = OnBackupTabShownAsync(); }
            if (name == "Optimize") { var _ = OnOptimizeTabShownAsync(); }
            if (name == "Firewall") { var _ = OnFwTabShownAsync(); }
        }

        private void UpdateDash()
        {
            if (_suspendDash) return;   // one refresh for a whole load or a Select All, not one per row
            var running = _phase == "Download" || _phase == "Install";
            var onOwner = (_batchTab == "Install" && _tab == "Install") || (_batchTab == "Un" && _tab == "Uninstall") || (_batchTab == "Update" && _tab == "Update") ||
                          (_batchTab == "Users" && _tab == "User Accounts") || (_batchTab == "Tools" && _tab == "Toolbox") ||
                          ((_batchTab == "Migrate" || _batchTab == "Share") && _tab == "Data Backup") || (_batchTab == "Tweak" && _tab == "Optimize") ||
                          (_batchTab == "Fw" && _tab == "Firewall");
            RowNow.Visibility = ((running || _phase == "Done") && onOwner) ? Visibility.Visible : Visibility.Collapsed;
            RowProgress.Visibility = (running && onOwner) ? Visibility.Visible : Visibility.Collapsed;
            BtnCancel.Visibility = (running && onOwner) ? Visibility.Visible : Visibility.Collapsed;
            if (running)
            {
                if (!onOwner) TxtStatus.Text = "";
                return;
            }
            if (_tab == "Install")
            {
                var sel = _items.Where(i => i.IsSelected).ToList();
                long sum = sel.Sum(i => i.SizeBytes);
                TxtStatus.Text = _items.Count + " apps available    |    " + sel.Count + " selected  (" + Format.Size(sum) + ")";
            }
            else if (_tab == "Uninstall") TxtStatus.Text = UnDashText();
            else if (_tab == "Update") TxtStatus.Text = UpdDashText();
            else if (_tab == "Toolbox") TxtStatus.Text = ToolsDashText();
            else if (_tab == "Data Backup") TxtStatus.Text = BackupDashText();
            else if (_tab == "Optimize") TxtStatus.Text = OptDashText();
            else if (_tab == "Firewall") TxtStatus.Text = FwDashText();
            else if (_tab == "Activity Log") TxtStatus.Text = _log.Path != null ? "Session log: " + _log.Path : "";
            else TxtStatus.Text = "";
        }

        // ------------------------------------------------------------------ the install button

        private void OnInstallClick()
        {
            var sel = _items.Where(i => i.IsSelected).ToList();
            if (_phase == "Idle" || _phase == "Done")
            {
                if (sel.Count == 0) { ShowOverlay("Nothing selected", "Select at least one application to install."); return; }
                ShowPreflight(sel, "install");
                return;
            }
            if (_phase == "Download")
            {
                var add = sel.Where(i => !_pending.Contains(i)).ToList();
                if (add.Count == 0) { ShowOverlay("Nothing to add", "Everything ticked is already in this batch."); return; }
                foreach (var h in add.Where(BatchPlan.IsInstalled).ToList())
                {
                    h.IsSelected = false;
                    SetStatus(h, "Already installed", "ok"); SetRing(h, "ok");
                    add.Remove(h);
                }
                if (add.Count == 0) return;
                var need = BatchPlan.SpaceNeeded(add, _cacheDir);
                var free = FreeSpace();
                if (free >= 0 && need > free)
                {
                    ShowOverlay("Not enough disk space", "Adding these needs " + Format.Size(need) + " and the drive has " + Format.Size(free) + " free.");
                    return;
                }
                foreach (var it in add)
                {
                    SetStatus(it, "Queued", "neutral"); it.ProgressVis = "Collapsed"; SetRing(it, "queued");
                    it.Chain = false; it.After = new string[0]; it.Dirty = false; it.CreatedPaths = new string[0];
                    _pending.Add(it);
                }
                Log("Added " + Format.Count(add.Count, "app", "apps") + " to the running batch.");
                SyncBatchStrip();
                return;
            }
            if (_phase == "Install")
            {
                var add = sel.Where(i => !_pending.Contains(i) && !_deferred.Contains(i)).ToList();
                if (add.Count == 0) { ShowOverlay("Nothing to add", "Everything ticked is already in this batch or queued for the next one."); return; }
                foreach (var it in add) { SetStatus(it, "Queued (next batch)", "neutral"); SetRing(it, "queued"); _deferred.Add(it); }
                Log(Format.Count(add.Count, "app", "apps") + " queued for the next batch - it starts when this one finishes, with one more UAC prompt.");
            }
        }

        // ------------------------------------------------------------------ pre-flight

        private string _pfAction = "install";

        private void ShowPreflight(List<AppItem> sel, string action)
        {
            _pfAction = action;
            // smallest first, a base ahead of its add-on: the sheet mirrors the order the batch will run
            _pfItems = action == "install" ? BatchPlan.Order(sel, _items) : sel.ToList();
            _pfHave.Clear(); _pfMissing.Clear();
            ChkPfHave.IsChecked = false;
            TxtPfHaveChk.Text = action == "install" ? "Reinstall over the existing copies anyway" : "Run the uninstaller anyway";
            if (action == "uninstall")
            {
                // the mirror guard: a row whose detect target is already gone is skipped unless asked
                foreach (var p in _pfItems) if (UninstallList.RowGone(p)) _pfHave.Add(p.Id);
            }
            else
            {
                try
                {
                    var inst = new Dictionary<string, bool>(StringComparer.Ordinal);
                    foreach (var c in _items) inst[c.Id] = BatchPlan.IsInstalled(c);
                    foreach (var p in _pfItems) if (inst.ContainsKey(p.Id) && inst[p.Id]) _pfHave.Add(p.Id);
                    // an id the catalog does not know is logged and skipped, never a reason the batch will not start
                    List<KeyValuePair<AppItem, string>> unknown;
                    _pfMissing.AddRange(BatchPlan.MissingBases(_pfItems, inst, out unknown));
                    foreach (var u in unknown) Log(u.Key.Name + " requires '" + u.Value + "', which is not in this catalog - the dependency check was skipped for it.");
                }
                catch (Exception ex)
                {
                    Log("Dependency check failed: " + ex.Message + " - continuing without it.");
                    _pfMissing.Clear();
                }
            }
            SyncPreflight();
            if (_pfItems.Count == 0) return;
            PreflightOverlay.Opacity = 0;
            PreflightOverlay.Visibility = Visibility.Visible;
            PreflightOverlay.BeginAnimation(OpacityProperty, new DoubleAnimation(0, 1, new Duration(TimeSpan.FromMilliseconds(180))));
        }

        private void HidePreflight() { PreflightOverlay.Visibility = Visibility.Collapsed; }

        private List<AppItem> PfCommitItems()
        {
            var reinstall = ChkPfHave.IsChecked == true;
            return _pfItems.Where(p => reinstall || !_pfHave.Contains(p.Id)).ToList();
        }

        private void SyncPreflight()
        {
            var reinstall = ChkPfHave.IsChecked == true;
            var install = _pfAction == "install";
            var tagOn = install ? "reinstall" : "run anyway";
            var tagOff = install ? "installed - skipped" : "already removed - skipped";
            _pfRows.Clear();
            foreach (var p in _pfItems)
            {
                _pfRows.Add(new PreflightRow
                {
                    Item = p,
                    SizeText = p.SizeBytes > 0 ? Format.Size(p.SizeBytes) : "size unknown",
                    HaveText = _pfHave.Contains(p.Id) ? (reinstall ? tagOn : tagOff) : "",
                });
            }
            TxtPfTitle.Text = install ? "Install " + Format.Count(_pfItems.Count, "application", "applications")
                                      : "Uninstall " + _pfItems.Count + (_pfItems.Count == 1 ? " application" : " applications");
            TxtPfSub.Text = "";

            var have = _pfItems.Where(p => _pfHave.Contains(p.Id)).ToList();
            if (have.Count > 0)
            {
                var names = string.Join(", ", have.Select(h => h.Name));
                TxtPfHaveNote.Text = install
                    ? (have.Count == 1 ? have[0].Name + " is already installed on this machine, so it is skipped."
                                       : have.Count + " of these are already installed on this machine, so they are skipped: " + names + ".")
                    : (have.Count == 1 ? names + " is no longer on this machine, so it is skipped."
                                       : have.Count + " of these are no longer on this machine, so they are skipped: " + names + ".");
                PfHave.Visibility = Visibility.Visible;
            }
            else PfHave.Visibility = Visibility.Collapsed;

            if (!install)
            {
                // an uninstall has no dependency picture and no disk verdict: only what may come back
                PfDep.Visibility = Visibility.Collapsed;
                var commitUn = PfCommitItems();
                long backBytes = commitUn.Sum(c => c.SizeBytes);
                TxtPfDiskWhere.Text = "Reclaimed";
                TxtPfDiskFacts.Text = backBytes > 0 ? "up to " + Format.Size(backBytes) : "size not reported";
                TxtPfDiskFacts.Foreground = Res("Muted");
                PfBarUsed.Width = 0; PfBarNeed.Width = 0;
                TxtPfDiskNote.Text = "";
                TxtPfFoot.Text = "";
                BtnPfGo.Content = "Uninstall " + commitUn.Count;
                BtnPfGo.IsEnabled = commitUn.Count > 0;
                return;
            }

            var missing = _pfMissing.Where(m => !_pfItems.Any(p => p.Id == m.Value)).ToList();
            if (missing.Count > 0)
            {
                var m = missing[0];
                var baseItem = _items.FirstOrDefault(i => i.Id == m.Value);
                var baseName = baseItem != null ? baseItem.Name : m.Value;
                TxtPfDepNote.Text = m.Key.Name + " needs " + baseName + ", which is not on this machine and not in this batch. Add it, or take " + m.Key.Name + " out.";
                TxtPfDepNote.Foreground = Res("Bad");
                if (baseItem != null)
                {
                    BtnPfAddDep.Content = "Add " + baseName + "   (" + (baseItem.SizeBytes > 0 ? Format.Size(baseItem.SizeBytes) : "size unknown") + ")";
                    BtnPfAddDep.Visibility = Visibility.Visible;
                }
                else BtnPfAddDep.Visibility = Visibility.Collapsed;
                PfDep.Visibility = Visibility.Visible;
            }
            else PfDep.Visibility = Visibility.Collapsed;

            var commit = PfCommitItems();
            long bytes = commit.Sum(c => c.SizeBytes);
            var need = BatchPlan.SpaceNeeded(commit, _cacheDir);
            long free = -1, total = 0; var where = "Disk";
            try
            {
                var d = new DriveInfo(Path.GetPathRoot(Path.GetFullPath(_cacheDir)));
                if (d.IsReady) { free = d.AvailableFreeSpace; total = d.TotalSize; where = "Disk " + d.Name.TrimEnd('\\'); }
            }
            catch { }
            TxtPfDiskWhere.Text = where;
            TxtPfDiskFacts.Text = Format.Size(bytes) + " to download   -   " + (free >= 0 ? Format.Size(free) + " free" : "free space unknown");
            const double w = 460.0;
            var used = Math.Max(0, total - Math.Max(0, free));
            var tot = total < 1 ? 1.0 : total;
            var usedW = Math.Max(0, Math.Min(w, w * used / tot));
            var needW = Math.Max(0, Math.Min(w - usedW, w * need / tot));
            if (need > 0 && needW < 4) needW = Math.Min(4, w - usedW);
            PfBarUsed.Width = usedW; PfBarNeed.Width = needW;
            var verdict = BatchPlan.DiskVerdict(free, total, need);
            PfBarUsed.Background = Res(verdict); PfBarUsed.Opacity = 0.55;
            PfBarNeed.Background = Res(verdict == "Good" ? "Accent" : verdict);
            if (free >= 0 && need > free)
            {
                TxtPfDiskFacts.Foreground = Res("Bad"); TxtPfDiskNote.Foreground = Res("Bad");
                TxtPfDiskNote.Text = "This will not fit - it needs " + Format.Size(need) + " with room to unpack, which is " + Format.Size(need - free) +
                                     " short, and installers need room beyond that again. Take something out, or free up space.";
            }
            else if (verdict == "Warn" || (free >= 0 && need > free / 2))
            {
                TxtPfDiskFacts.Foreground = Res("Warn"); TxtPfDiskNote.Foreground = Res("Muted");
                TxtPfDiskNote.Text = (free >= 0 && need > free / 2)
                    ? "That is over half the free space on this drive. " + Format.Size(need) + " covers the download and room to unpack it - each installer then writes its own files on top of that."
                    : "It fits, but the drive is nearly full: " + Format.Size(free - need) + " would be left, and Windows slows down and fails updates below about 10% free. Worth clearing space first.";
            }
            else
            {
                TxtPfDiskFacts.Foreground = Res("Good"); TxtPfDiskNote.Foreground = Res("Dim");
                TxtPfDiskNote.Text = "Room for the download and for unpacking it (" + Format.Size(need) + "). What each installer then writes is its own, and is not counted here.";
            }
            TxtPfFoot.Text = "Downloads to " + _cacheDir;
            BtnPfGo.Content = "Install " + commit.Count;
            BtnPfGo.IsEnabled = commit.Count > 0 && missing.Count == 0;
        }

        private void PfRemove_Click(object sender, RoutedEventArgs e)
        {
            var item = (sender as Button)?.Tag as AppItem;
            if (item == null) return;
            _pfItems.Remove(item);
            if (_pfItems.Count == 0) { HidePreflight(); return; }
            SyncPreflight();
        }

        private void PfAddMissing()
        {
            foreach (var m in _pfMissing.ToList())
            {
                var baseItem = _items.FirstOrDefault(i => i.Id == m.Value);
                if (baseItem != null && !_pfItems.Contains(baseItem)) _pfItems.Add(baseItem);
            }
            _pfItems = BatchPlan.Order(_pfItems, _items);
            foreach (var p in _pfItems) if (BatchPlan.IsInstalled(p)) _pfHave.Add(p.Id);
            SyncPreflight();
        }

        // the batch strip's owner check and the Install-phase seam both need to know which tab is running
        private bool BatchIsUninstall { get { return _batchTab == "Un"; } }

        // ------------------------------------------------------------------ the batch

        private void StartBatch(List<AppItem> sel)
        {
            var need = BatchPlan.SpaceNeeded(sel, _cacheDir);
            var free = FreeSpace();
            if (free >= 0 && need > free)
            {
                ShowOverlay("Not enough disk space", "This batch needs " + Format.Size(need) + " and the drive has " + Format.Size(free) + " free.");
                return;
            }
            foreach (var p in sel)
            {
                SetStatus(p, "Queued", "neutral"); SetRing(p, "queued");
                p.Dirty = false; p.CreatedPaths = new string[0]; p.ProgressVis = "Collapsed"; p.Chain = false; p.After = new string[0];
            }
            _pending = sel.ToList();
            _batchTab = "Install";
            _deepClean = false; _forceMode = false;
            foreach (var p in _pending) p.BatchAction = null;
            _cancelRequested = false; _hadFailures = false; _awaitingScan = false;
            _urlRefreshed.Clear(); _lastLogKey.Clear();
            _runStarted = DateTime.Now;
            _worker.ResetForBatch();
            ShowBatchStrip();
            _phase = "Download";
            TxtNow.Text = "Starting downloads...";
            DotNow.Fill = Res("Lift");
            TxtStatus.Text = "Downloading...";
            TxtInstallBtn.Text = "Add to Batch";
            BarOverall.Value = 0; TxtOverall.Text = "";
            Log("Batch started: " + Format.Count(_pending.Count, "application", "applications") + ", " + Format.Size(_pending.Sum(p => p.SizeBytes)) + " total.");
            UpdateDash();
            _dlCts = new CancellationTokenSource();
            var _ = RunDownloadsAsync(_dlCts.Token);
        }

        private string CachePath(AppItem item)
        {
            var dir = Path.Combine(_cacheDir, "files", Catalog.SafeId(item.Id));
            Directory.CreateDirectory(dir);
            return Path.Combine(dir, item.FileName);
        }

        private long FreeSpace()
        {
            try { return new DriveInfo(Path.GetPathRoot(Path.GetFullPath(_cacheDir))).AvailableFreeSpace; } catch { return -1; }
        }

        private async Task RunDownloadsAsync(CancellationToken ct)
        {
            try
            {
                for (_dlIndex = 0; _dlIndex < _pending.Count; _dlIndex++)
                {
                    if (ct.IsCancellationRequested) break;
                    var item = _pending[_dlIndex];
                    var st = item.Status ?? "";
                    if (st.StartsWith("Removed") || st.StartsWith("Skipped") || st.StartsWith("Cancelled")) continue;
                    var dest = CachePath(item);
                    // already fully present (size matches) -> the hash gets verified by the worker anyway.
                    // Only when the catalog STATES a size: with sizeBytes 0 an empty leftover file matched.
                    if (item.SizeBytes > 0 && File.Exists(dest) && new FileInfo(dest).Length == item.SizeBytes)
                    {
                        await EnqueueAsync(item, dest);
                        if (_phase == "Done") return;
                        continue;
                    }
                    SetStatus(item, "Starting download", "active"); SetRing(item, "download");
                    try
                    {
                        var it = item;
                        // several connections for a large file, one resumable connection otherwise (Downloads decides)
                        await Downloads.FetchAsync(_edge, it, dest,
                            () => RefreshUrlAsync(it),
                            () => (it.Status ?? "").StartsWith("Removed"),
                            (done, total, text, kind) => Ui(() => OnDlStatus(it, done, total, text, kind)),
                            line => Ui(() => Log(line)),
                            ct);
                        item.ProgressVis = "Collapsed";
                        Log(item.Name + " downloaded.");
                        await EnqueueAsync(item, dest);
                        if (_phase == "Done") return;
                    }
                    catch (OperationCanceledException)
                    {
                        item.ProgressVis = "Collapsed";
                        Log(item.Name + ": download stopped - the batch was cancelled.");
                        break;
                    }
                    catch (DownloadRemovedException)
                    {
                        item.ProgressVis = "Collapsed";
                        Log(item.Name + ": download stopped - removed from the batch.");
                    }
                    catch (Exception ex)
                    {
                        SetStatus(item, "Failed: " + ex.Message, "fail"); SetRing(item, "fail");
                        item.ProgressVis = "Collapsed";
                        Log("Download failed for " + item.Name + ": " + ex.Message);
                        _hadFailures = true;
                    }
                }
            }
            catch (Exception ex)
            {
                Log("The download loop stopped: " + ex.Message);
                _hadFailures = true;
            }
            if (_phase == "Done") return;
            if (_worker.Started)
            {
                // The end marker is NOT sent here: the worker is released once every app has reported
                _awaitingScan = true;
                _phase = "Install";
                if (_cancelRequested) { TxtStatus.Text = "Cancelling - waiting for the installer to stop..."; _worker.Complete(); }
                else { TxtStatus.Text = "Installing remaining apps..."; TxtInstallBtn.Text = "Queue Next Batch"; }
            }
            else FinishBatch();   // nothing downloaded successfully, no worker ever started
        }

        /// <summary>
        /// The download's own sentence for the row - "Downloading 43%  9.1 MB/s  -  2m 10s left",
        /// "Internet lost - waiting; 43% kept, resumes on its own", "reconnecting 3 of 16". Never over
        /// a verdict: a Remove or Cancel click sets its word while the workers are still mid-read.
        /// </summary>
        private void OnDlStatus(AppItem item, long done, long total, string text, string kind)
        {
            var st = item.Status ?? "";
            if (st.StartsWith("Removed") || st.StartsWith("Cancelled") || st.StartsWith("Failed")) return;
            SetStatus(item, text, kind);
            if (done < 0) return;   // a note without a position (a link refresh) leaves the bar where it was
            var pct = total > 0 ? (int)Math.Floor(done * 100.0 / total) : 0;
            item.ProgressVis = "Visible";
            item.Progress = pct;
            UpdateOverall(pct);
        }

        /// <summary>The download phase's bar: bytes, which is a real number.</summary>
        private void UpdateOverall(int pct)
        {
            var total = _pending.Count;
            if (total == 0) return;
            BarOverall.IsIndeterminate = false;
            BarOverall.Value = Math.Min(100, ((_dlIndex * 100) + pct) / (double)total);
            TxtOverall.Text = Math.Floor(BarOverall.Value) + "%   -   app " + Math.Min(_dlIndex + 1, total) + " of " + total;
        }

        /// <summary>
        /// The execution phase's bar, from the rows themselves - so every batch kind has one, not
        /// just the two that download. A row counts when it settles; a row the worker reports a
        /// percentage for (a long copy, a scan) adds its own share while it runs. When nothing has
        /// settled and nothing reports a number, the bar sweeps instead: that says "working"
        /// without claiming a figure the run cannot support.
        /// </summary>
        private void UpdateOverallRows()
        {
            if (_pending.Count == 0) return;
            var o = BatchPlan.OverallFor(_pending);
            BarOverall.IsIndeterminate = false;   // the execution bar always has a figure now
            // floored to match the caption: 99.6 drew a bar indistinguishable from full beside
            // the words "99%"
            BarOverall.Value = Math.Floor(o.Value);
            TxtOverall.Text = o.Text;
        }

        /// <summary>Get-FreshCatalogUrl: only the URL is taken; a changed hash means a republish, and the download fails honestly.</summary>
        private async Task<string> RefreshUrlAsync(AppItem item)
        {
            if (_urlRefreshed.Contains(item.Id)) return null;
            _urlRefreshed.Add(item.Id);
            try
            {
                var text = await _edge.GetCatalogAsync(CancellationToken.None).ConfigureAwait(false);
                var root = Json.ParseObject(text);
                var entry = Json.Arr(root, "apps").OfType<Dictionary<string, object>>().FirstOrDefault(a => Json.Str(a, "id") == item.Id);
                if (entry == null || Json.Str(entry, "url").Length == 0) { Log("Catalog refresh: " + item.Name + " is no longer in the catalog."); return null; }
                var url = Json.Str(entry, "url");
                if (!Regex.IsMatch(url, "^(?i)(https?|file)://")) { Log("Catalog refresh: " + item.Name + " now has a url that is not http(s):// - not switching."); return null; }
                if (!string.Equals(Json.Str(entry, "sha256"), item.Sha256, StringComparison.OrdinalIgnoreCase))
                { Log("Catalog refresh: " + item.Name + " was republished with a different SHA-256 - not switching URLs mid-download."); return null; }
                return url;
            }
            catch (Exception ex) { Log("Catalog refresh failed for " + item.Name + ": " + ex.Message); return null; }
        }

        /// <summary>Enqueue-Install: post-install payloads fetched and hashed here, then the entry crosses to the elevated side.</summary>
        private async Task EnqueueAsync(AppItem item, string dest)
        {
            if (!_worker.Start()) { AbortBatch("the administrator prompt was declined, so nothing was run", "warn"); return; }
            var steps = new List<Dictionary<string, object>>();
            foreach (var o in item.PostInstall ?? new object[0])
            {
                var st = o as Dictionary<string, object>;
                if (st == null) continue;
                string local = null;
                var url = Json.Str(st, "url");
                if (url.Length > 0)
                {
                    var fn = Catalog.FileNameOf(url);
                    if (string.IsNullOrEmpty(fn)) fn = "post-" + Guid.NewGuid().ToString("N").Substring(0, 8);
                    local = Path.Combine(Path.GetDirectoryName(dest), fn);
                    var want = Json.Str(st, "sha256").ToUpperInvariant();
                    // Reuse has to be earned: matching hash, or fetch it again. The cache folder is
                    // writable by anything running as this user.
                    var reuse = false;
                    if (File.Exists(local))
                    {
                        if (want.Length > 0) { try { reuse = WorkerHost.Sha256Hex(local) == want; } catch { reuse = false; } }
                        if (!reuse) { try { File.Delete(local); } catch { } }
                    }
                    if (!reuse)
                    {
                        Log(item.Name + ": fetching post-install file " + fn);
                        var ok = await _edge.GetFileAsync(url, local, 60, CancellationToken.None);
                        if (!ok)
                        {
                            Log(item.Name + ": could not download post-install file " + fn);
                            SetStatus(item, "Failed: post-install file " + fn + " unavailable", "fail"); SetRing(item, "fail");
                            _hadFailures = true;
                            return;
                        }
                    }
                }
                steps.Add(BatchPlan.StepFor(st, local));
            }
            if (steps.Count > 0) Log(item.Name + ": " + Format.Count(steps.Count, "post-install step", "post-install steps") + " queued.");
            item.PreExisting = (item.VerifyPaths ?? new string[0]).Any(vp => !string.IsNullOrEmpty(vp) &&
                (File.Exists(Environment.ExpandEnvironmentVariables(vp)) || Directory.Exists(Environment.ExpandEnvironmentVariables(vp))));
            var sid = "";
            try { using (var id = WindowsIdentity.GetCurrent()) sid = id.User.Value; } catch { }
            _worker.Enqueue(BatchPlan.InstallEntry(item, dest, sid, steps));
            SetStatus(item, "Queued for install", "ready");
            Log(item.Name + " -> Queued for install");
            item.Progress = 100;
            SetRing(item, "download");
        }

        private void AbortBatch(string reason) { AbortBatch(reason, "fail"); }

        /// <summary>
        /// kind: "fail" for something that genuinely broke, "warn" for a batch that never started.
        ///
        /// Declining the administrator prompt was reported as "Failed: elevation declined" on EVERY
        /// row, in red, counted as "0 completed, 3 failed", with the download cache kept and the
        /// batch remembered as a failure - for a batch in which nothing was attempted. A refusal
        /// reported as a failure is a shape this product has already been caught on twice; it must
        /// not be the shape of its own abort path.
        /// </summary>
        private void AbortBatch(string reason, string kind)
        {
            try { if (_dlCts != null) _dlCts.Cancel(); } catch { }
            if (_worker.Started && !_worker.EndQueued) _worker.Complete();
            var word = (kind == "warn" ? "Not run: " : "Failed: ") + reason;
            foreach (var p in _pending)
            {
                var st = p.Status ?? "";
                if (!st.StartsWith("Installed") && !st.StartsWith("Failed") && !st.StartsWith("Remov"))
                { SetStatus(p, word, kind); SetRing(p, kind); }
            }
            if (kind != "warn") _hadFailures = true;
            // FinishBatch returns on its first line unless a batch is actually under way, and the ten
            // worker-only starters call Start() BEFORE setting the phase - so a declined UAC used to
            // abort into nothing: the strip stayed on screen, live, with its close button hidden.
            if (_phase != "Download" && _phase != "Install") _phase = "Install";
            FinishBatch();
        }

        private void OnCancel()
        {
            if (_phase != "Download" && _phase != "Install") return;
            if (CancelUninstallSpecial()) return;
            _cancelRequested = true;
            _worker.RequestCancel();
            foreach (var p in _pending)
            {
                if (BatchPlan.Removable(p.Status, _batchLive)) { SetStatus(p, "Cancelled", "warn"); SetRing(p, "warn"); p.ProgressVis = "Collapsed"; }
            }
            Log("Cancel requested - downloads stop now; an installer that has already started finishes on its own.");
            TxtStatus.Text = "Cancelling...";
            if (_worker.Started) _worker.Complete();
            try { if (_dlCts != null) _dlCts.Cancel(); } catch { }
            if (_phase == "Install" && !_worker.Started) FinishBatch();
        }

        private void Tick()
        {
            if (_busy) return;
            _busy = true;
            try
            {
                if (_worker.Started && (_phase == "Download" || _phase == "Install")) ReadWorkerStatus();
                if (_phase == "Download" || _phase == "Install") SyncBatchStrip();
                // the bar, four times a second: bytes while downloading, settled rows once the
                // worker is executing - the download figure would otherwise stand at 100% through
                // every install, and a worker-only batch would never move at all
                if (_phase == "Install") UpdateOverallRows();
                if (_phase == "Install" && _awaitingScan && _pending.All(p => BatchPlan.IsTerminal(p.Status))) OnAllRowsSettled();
                CheckWorkerAlive();
            }
            catch (Exception ex) { Log("Tick failed: " + ex.Message); }
            finally { _busy = false; }
        }

        /// <summary>
        /// A batch can only end two ways: the worker writes its Complete line, or every row settles.
        /// A worker that dies - killed by endpoint protection, by Task Manager, or by its own crash -
        /// does neither, and the tool used to sit on the last status line for ever with every other
        /// tab refusing "Still busy" and Cancel doing nothing visible. Now its death is a sentence.
        /// </summary>
        private DateTime _lastWorkerWord = DateTime.MinValue;   // when the worker last said anything

        private void CheckWorkerAlive()
        {
            if (!_worker.Started || _worker.Alive || _phase == "Done" || _phase == "Idle") return;
            // A process handle saying "exited" is not on its own enough to condemn a batch. If that
            // handle ever referred to something other than the worker, acting on it alone would end
            // good batches and mark finished installs as failed - worse than the hang it fixes. So
            // the worker must ALSO have gone quiet: ninety seconds without a single line, from a
            // process that reports gone, is dead. A working worker talks far more often than that.
            if (_lastWorkerWord == DateTime.MinValue) { _lastWorkerWord = DateTime.Now; return; }
            if ((DateTime.Now - _lastWorkerWord).TotalSeconds < 90) return;
            var code = _worker.ExitCode;
            var why = "the elevated worker stopped before it finished and said nothing for 90 seconds" + (code.HasValue ? " (exit " + code.Value + ")" : "");
            Log(why + " - anything it had not reported is marked failed. Antivirus on this machine is the usual cause.");
            foreach (var p in _pending)
                if (!BatchPlan.IsTerminal(p.Status)) { SetStatus(p, "Failed: " + why, "fail"); SetRing(p, "fail"); }
            _hadFailures = true;
            _awaitingScan = false;
            FinishBatch();
        }

        private void ReadWorkerStatus()
        {
            foreach (var s in _worker.ReadStatus())
            {
                _lastWorkerWord = DateTime.Now;   // proof of life for the watchdog
                if (s.Id == "_batch")
                {
                    if (!string.IsNullOrEmpty(s.Detail)) Log("Elevated worker: " + s.Detail);
                    FinishBatch();
                    return;
                }
                var item = _pending.FirstOrDefault(p => p.Id == s.Id);
                if (item == null) continue;
                if (s.Dirty) item.Dirty = true;
                if (s.Created.Length > 0) { item.CreatedPaths = s.Created; Log(item.Name + " installed into: " + string.Join(", ", s.Created)); }
                var w = BatchPlan.RowWords(s, item.Dirty, _batchTab);
                if (s.Pct >= 0) { item.Progress = s.Pct; item.ProgressVis = "Visible"; item.RingTrackVis = "Visible"; }
                // SetStatus logs a settled row itself when it shortens the sentence; every other
                // report is logged here, once per change - a 1 Hz profile copy must not push 3600
                // lines into the log
                var loggedBySet = BatchPlan.ShortStatus(w.Text, w.Kind) != w.Text && item.StatusDetail != w.Text;
                SetStatus(item, w.Text, w.Kind);
                SetRing(item, w.Ring);
                if (s.State == "Verifying file" || s.State == "Installing" || s.State == "Uninstalling" || s.State == "Applying" || s.State == "Undoing")
                {
                    TxtNow.Text = s.State + ": " + item.Name;
                    DotNow.Fill = Res("Lift");
                }
                if (!loggedBySet)
                {
                    var key = s.State + "|" + Regex.Replace(s.Detail ?? "", @" - \d+ file\(s\).*$", "");
                    string last;
                    if (s.Pct < 0 || !_lastLogKey.TryGetValue(item.Id, out last) || last != key)
                    {
                        _lastLogKey[item.Id] = key;
                        Log(w.Kind == "active" ? item.Name + ": " + w.Text : item.Name + " -> " + w.Text);
                    }
                }
            }
        }

        private void FinishBatch()
        {
            if (_phase == "Done" || _phase == "Idle") return;
            _phase = "Done";
            _batchLive = false;
            foreach (var p in _pending)
            {
                p.ProgressVis = "Collapsed"; p.SpinnerVis = "Collapsed";
                if (p.BadgeVis == "Collapsed") p.RingTrackVis = "Collapsed";
            }
            var done = _pending.Count(p => BatchPlan.IsDone(p.Status));
            var fail = _pending.Count(p => BatchPlan.IsFail(p.Status));
            var cans = _pending.Count(p => BatchPlan.IsGone(p.Status));
            _awaitingScan = false;
            if (fail > 0 || cans > 0) _hadFailures = true;
            // A batch that did not end cleanly must not hand the queued-next batch straight back
            // with a fresh UAC prompt. Cancel was the obvious case. The two that were missed are a
            // DECLINED elevation prompt - which raised a second prompt one tick after the first was
            // refused - and a worker the watchdog condemned, which followed a dead worker into a
            // fresh elevation request. This sits below the counts because _hadFailures is set there.
            if ((_cancelRequested || _hadFailures) && _deferred.Count > 0)
            {
                var why = _cancelRequested ? "the batch was cancelled" : "the batch did not finish cleanly";
                Log(Format.Count(_deferred.Count, "application", "applications") + " queued for the next batch were dropped - " + why + ".");
                foreach (var d in _deferred) { SetStatus(d, "Cancelled", "warn"); SetRing(d, "warn"); }
                _deferred.Clear();
            }
            // Anything that worked, or was skipped, unticks; a failure stays ticked so "press it again"
            // is the retry. Applied and Reverted belong here too: leaving a whole tweak batch ticked
            // turned "undo the one I got wrong" into "undo all twelve", because Undo takes the selection.
            foreach (var p in _pending)
                if (p.IsSelected && (BatchPlan.IsDone(p.Status) || (p.Status ?? "").StartsWith("Skipped"))) p.IsSelected = false;
            BarOverall.IsIndeterminate = false; BarOverall.Value = 100; TxtOverall.Text = "";
            var wasCancelled = _pending.Count(p => (p.Status ?? "").StartsWith("Cancelled"));
            var hadWarnings = _pending.Count(p => (p.Status ?? "").StartsWith("Skipped"));
            var wasRemoved = _pending.Count(p => (p.Status ?? "").StartsWith("Removed"));
            var notRun = _pending.Count(p => (p.Status ?? "").StartsWith("Skipped") && (p.StatusDetail ?? "").IndexOf("was not run", StringComparison.Ordinal) >= 0);
            hadWarnings -= notRun;
            var summary = done + " completed, " + fail + " failed";
            if (hadWarnings > 0) summary += ", " + hadWarnings + " with warnings";
            if (notRun > 0) summary += ", " + notRun + " not run";
            if (wasRemoved > 0) summary += ", " + wasRemoved + " removed";
            if (wasCancelled > 0) summary += ", " + wasCancelled + " cancelled";
            // a firewall batch answers how many rules were actually NEW - running it twice should
            // visibly change nothing rather than looking like it did the work again
            if (_batchTab == "Fw") summary = FirewallList.BatchSummary(_pending, summary);
            // a cleanup batch says what it gave back, summed from the rows' own measurements
            if (_batchTab == "Tweak") { var rb = Optimize.ReclaimedBytes(_pending); if (rb > 0) summary += ", " + Format.Size(rb) + " reclaimed"; }
            TxtStatus.Text = "Finished: " + summary;
            TxtNow.Text = "Finished - " + summary;
            DotNow.Fill = Brush(fail > 0 ? "#FFF87171" : (cans > 0 ? "#FFFBBF24" : "#FF34D399"));
            Log("Batch complete: " + summary + ".");
            WriteRunRecord();
            try { if (File.Exists(_worker.CancelPath)) File.Delete(_worker.CancelPath); } catch { }
            try { if (File.Exists(_worker.SkipPath)) File.Delete(_worker.SkipPath); } catch { }
            if (!_worker.Started || _worker.EndQueued) _worker.ClearQueueFile();
            if (!_hadFailures && !App.Opts.KeepCache) SweepCache();
            var dirty = _pending.Where(p => p.Dirty && BatchPlan.IsFail(p.Status)).Select(p => p.Name).ToList();
            if (dirty.Count > 0)
                Log("Left behind by a failed install: " + string.Join(", ", dirty) + ". The leftover sweep is in the script client's Uninstall tab for now.");
            OnBatchEndedUninstall();
            OnBatchEndedUpdate();
            OnBatchEndedUsers(summary, fail, cans);
            OnBatchEndedTools(summary, fail, cans);
            OnBatchEndedBackup(summary, done, fail, cans);
            OnBatchEndedTweak(summary);
            OnBatchEndedFw();
            SortBatchStrip();
            // A clean batch folds itself away: the strip has done its job and the tab underneath is
            // what the technician wants back. Trouble keeps it open - SortBatchStrip has just put the
            // failures on top, and folding them out of sight is the one thing this strip must not do.
            // It folds when the batch ends, whatever happened. Nothing is hidden by it:
            // SortBatchStrip has just put the failures on top, the header keeps the count
            // ("10 of 12 done, 2 failed") in view and says so in red, it says "click to open",
            // and the closing sheet reports the same numbers regardless.
            _batchFolded = true; _batchFollowing = null;
            SyncBatchStrip();
            TxtInstallBtn.Text = "Install Selected";
            // Eight starters disable this button and not one re-enabled it: after any firewall block,
            // tweak, account change, Toolbox fix, backup or share, Install was dead for the rest of
            // the session with nothing on screen to say why. One line here covers all of them.
            BtnInstall.IsEnabled = true;
            UpdateDash();
            var notes = _pending.Where(p => (p.Status ?? "").StartsWith("Installed") && !string.IsNullOrWhiteSpace(p.Instructions))
                                .Select(p => p.Name + ": " + p.Instructions.Trim()).ToList();
            if (notes.Count > 0) ShowOverlay("After installing", string.Join("\n\n", notes));
            if (_deferred.Count > 0)
            {
                var next = _deferred.ToList();
                _deferred.Clear();
                Log("Starting the queued batch (" + Format.Count(next.Count, "app", "apps") + ").");
                StartBatch(next);
                return;
            }
            if (App.Opts.AutoClose)
            {
                Log("Harness: batch ended, closing.");
                _forceClose = true;
                Dispatcher.BeginInvoke(new Action(Close), DispatcherPriority.Background);
            }
        }

        private void SweepCache()
        {
            try
            {
                var files = Path.Combine(_cacheDir, "files");
                if (!Directory.Exists(files)) return;
                var exts = new HashSet<string>(new[] { ".exe", ".msi", ".zip", ".rar", ".iso", ".part", ".parts" }, StringComparer.OrdinalIgnoreCase);
                var n = 0;
                foreach (var f in Directory.GetFiles(files, "*", SearchOption.AllDirectories))
                    if (exts.Contains(Path.GetExtension(f))) { try { File.Delete(f); n++; } catch { } }
                if (n > 0) Log("Cache swept: " + Format.Count(n, "downloaded file", "downloaded files") + " removed.");
            }
            catch { }
        }

        private void WriteRunRecord()
        {
            try
            {
                var now = DateTime.Now;
                var started = _runStarted == default(DateTime) ? now : _runStarted;
                Func<string, string> outcome = st =>
                {
                    if (BatchPlan.IsDone(st)) return "ok";
                    if (BatchPlan.IsFail(st)) return "failed";
                    if ((st ?? "").StartsWith("Skipped")) return "warned";
                    if ((st ?? "").StartsWith("Removed")) return "removed";
                    if ((st ?? "").StartsWith("Cancelled")) return "cancelled";
                    return "other";
                };
                var rows = _pending.Select(p => new Dictionary<string, object> {
                    { "id", p.Id }, { "name", p.Name }, { "outcome", outcome(p.Status) },
                    { "detail", string.IsNullOrEmpty(p.StatusDetail) ? p.Status : p.StatusDetail }, { "bytes", p.SizeBytes } }).ToList();
                var rec = new Dictionary<string, object>
                {
                    { "kind", _batchTab == "Un" ? "uninstall" : (_batchTab == "Update" ? "update" : (_batchTab == "Users" ? "users" : (_batchTab == "Tools" ? "tools"
                              : (_batchTab == "Migrate" ? "migrate" : (_batchTab == "Share" ? "share" : (_batchTab == "Tweak" ? "optimize" : (_batchTab == "Fw" ? "firewall" : "install"))))))) },
                    { "started", started.ToString("s") }, { "finished", now.ToString("s") },
                    { "seconds", (int)(now - started).TotalSeconds },
                    { "counts", new Dictionary<string, object> {
                        { "total", rows.Count }, { "ok", rows.Count(r => (string)r["outcome"] == "ok") }, { "failed", rows.Count(r => (string)r["outcome"] == "failed") },
                        { "warned", rows.Count(r => (string)r["outcome"] == "warned") }, { "removed", rows.Count(r => (string)r["outcome"] == "removed") },
                        { "cancelled", rows.Count(r => (string)r["outcome"] == "cancelled") } } },
                    { "items", rows }, { "client", App.BuildTag },
                };
                var dir = Path.Combine(_cacheDir, "runs");
                Directory.CreateDirectory(dir);
                File.WriteAllText(Path.Combine(dir, "run-" + now.ToString("yyyyMMdd-HHmmss") + ".json"), Json.Serialize(rec), new UTF8Encoding(false));
                foreach (var old in Directory.GetFiles(dir, "run-*.json").OrderByDescending(f => f).Skip(20)) { try { File.Delete(old); } catch { } }
            }
            catch (Exception ex) { Log("Could not write the run record: " + ex.Message); }
        }

        // ------------------------------------------------------------------ rows

        private void SetStatus(AppItem item, string text, string kind)
        {
            if (!Dispatcher.CheckAccess()) { Dispatcher.BeginInvoke(new Action(() => SetStatus(item, text, kind))); return; }
            string fg;
            item.StatusFg = BatchPlan.StatusPalette.TryGetValue(kind, out fg) ? fg : BatchPlan.StatusPalette["neutral"];
            var shortText = BatchPlan.ShortStatus(text, kind);
            if (shortText != text && item.StatusDetail != text) Log(item.Name + " -> " + text);
            item.StatusDetail = text;
            item.Status = shortText;
        }

        private void SetRing(AppItem item, string state)
        {
            switch (state)
            {
                case "queued": item.Progress = 0; item.RingTrackVis = "Visible"; item.SpinnerVis = "Collapsed"; item.BadgeVis = "Collapsed"; break;
                case "download": item.RingTrackVis = "Visible"; item.SpinnerVis = "Collapsed"; item.BadgeVis = "Collapsed"; break;
                case "busy": item.RingTrackVis = "Collapsed"; item.SpinnerVis = "Visible"; item.BadgeVis = "Collapsed"; break;
                case "ok": item.RingTrackVis = "Collapsed"; item.SpinnerVis = "Collapsed"; item.BadgeBg = "#FF22C55E"; item.BadgeData = "M 8,13.5 L 11.5,17 L 18,9.5"; item.BadgeVis = "Visible"; break;
                case "fail": item.RingTrackVis = "Collapsed"; item.SpinnerVis = "Collapsed"; item.BadgeBg = "#FFEF4444"; item.BadgeData = "M 9.5,9.5 L 16.5,16.5 M 16.5,9.5 L 9.5,16.5"; item.BadgeVis = "Visible"; break;
                case "warn": item.RingTrackVis = "Collapsed"; item.SpinnerVis = "Collapsed"; item.BadgeBg = "#FFF59E0B"; item.BadgeData = "M 13,7.5 L 13,14 M 13,17 L 13,17.01"; item.BadgeVis = "Visible"; break;
                default: item.RingTrackVis = "Collapsed"; item.SpinnerVis = "Collapsed"; item.BadgeVis = "Collapsed"; break;
            }
        }

        // ------------------------------------------------------------------ the batch strip

        private void ShowBatchStrip()
        {
            _batchRows.Clear();
            foreach (var p in _pending) _batchRows.Add(p);
            _batchLive = true; _batchFolded = false; _batchFollowing = null;
            _lastWorkerWord = DateTime.MinValue;   // the watchdog's clock starts with the batch, whichever tab began it
            BatchStrip.Visibility = Visibility.Visible;
            BtnBatchClose.Visibility = Visibility.Collapsed;
            // every batch starts the bar at nothing. Eight starters call this; only the install one
            // used to reset the bar, so a cleanup or a fix inherited the last batch's 100%.
            BarOverall.IsIndeterminate = false; BarOverall.Value = 0; TxtOverall.Text = "";
            SyncBatchStrip();
        }

        private void SyncBatchStrip()
        {
            foreach (var p in _pending) if (!_batchRows.Contains(p)) _batchRows.Add(p);
            if (BatchStrip.Visibility != Visibility.Visible) return;
            BatchScroll.Visibility = _batchFolded ? Visibility.Collapsed : Visibility.Visible;
            BatchChevron.Data = Geometry.Parse(_batchFolded ? "M 4,7 L 9,12 L 14,7" : "M 4,11 L 9,6 L 14,11");
            BtnBatchClose.Visibility = _batchLive ? Visibility.Collapsed : Visibility.Visible;
            int done = 0, fail = 0, gone = 0, left = 0;
            foreach (var p in _batchRows)
            {
                var st = p.Status ?? "";
                if (BatchPlan.IsDone(st)) done++;
                else if (BatchPlan.IsFail(st)) fail++;
                else if (BatchPlan.IsGone(st)) gone++;
                else left++;
                var want = BatchPlan.Removable(p.Status, _batchLive) ? "Visible" : "Collapsed";
                if (p.RemoveVis != want) p.RemoveVis = want;
            }
            var head = "BATCH   " + done + " of " + _batchRows.Count + " done";
            if (fail > 0) head += ", " + fail + " failed";
            if (gone > 0) head += ", " + gone + " removed";
            if (left > 0 && _batchLive) head += ", " + left + " to go";
            // folded away with something to look at: say that the list is one click from here,
            // rather than leaving a number on screen with no way in that anyone would notice
            if (_batchFolded && !_batchLive && (fail > 0 || gone > 0)) head += "   -   click to open";
            TxtBatchHead.Text = head;
            TxtBatchHead.Foreground = (Brush)(fail > 0 ? FindResource("Bad") : FindResource("Dim"));
            FollowActiveRow();
        }

        // the row the strip is currently keeping in view; null until one is found
        private AppItem _batchFollowing;

        /// <summary>
        /// Keep the row the worker is actually on inside the visible part of the strip. The strip
        /// caps at 230 px - about seven rows - so a batch of twenty scrolls its working row out of
        /// sight within seconds and leaves the technician watching a column of "Queued".
        /// Only a CHANGE of active row scrolls: re-asserting it four times a second would fight a
        /// technician who scrolled up to read a failure. A row whose container does not exist yet
        /// is not recorded, so the next tick tries again.
        /// </summary>
        private void FollowActiveRow()
        {
            if (_batchFolded || !_batchLive || BatchStrip.Visibility != Visibility.Visible) return;
            var active = BatchPlan.ActiveRow(_batchRows);
            if (active == null || ReferenceEquals(active, _batchFollowing)) return;
            var el = ListBatch.ItemContainerGenerator.ContainerFromItem(active) as FrameworkElement;
            if (el == null) return;   // not generated yet - leave _batchFollowing alone and retry next tick
            _batchFollowing = active;
            el.BringIntoView();
        }

        /// <summary>Failures to the top once the batch has ended. Reordering is fine here and nowhere else.</summary>
        private void SortBatchStrip()
        {
            Func<AppItem, int> rank = p => BatchPlan.IsFail(p.Status) ? 0 : (BatchPlan.IsGone(p.Status) ? 1 : 2);
            var ordered = _batchRows.Select((p, i) => new { p, i }).OrderBy(x => rank(x.p)).ThenBy(x => x.i).Select(x => x.p).ToList();
            _batchRows.Clear();
            foreach (var p in ordered) _batchRows.Add(p);
        }

        private void ClearStrip()
        {
            BatchStrip.Visibility = Visibility.Collapsed;
            foreach (var p in _batchRows)
            {
                p.Status = ""; p.StatusDetail = ""; p.ProgressVis = "Collapsed"; SetRing(p, "none");
            }
            // dismissing the results is also the moment the Optimize and Toolbox cards let go of
            // theirs - including the verdicts a Detect or a pre-apply check left on rows the batch never ran
            foreach (var p in _tweakItems.Concat(_cleanItems).Concat(_startupItems).Concat(_fixItems))
            {
                if (string.IsNullOrEmpty(p.Status)) continue;
                p.Status = ""; p.StatusDetail = ""; p.ProgressVis = "Collapsed"; SetRing(p, "none");
            }
            _batchRows.Clear();
            _pending = new List<AppItem>();
            _phase = "Idle";
            UpdateDash();
        }

        private void BatchRemove_Click(object sender, RoutedEventArgs e)
        {
            var item = (sender as Button)?.Tag as AppItem;
            if (item != null) RemoveFromBatch(item);
        }

        private void RemoveFromBatch(AppItem item)
        {
            if (!BatchPlan.Removable(item.Status, _batchLive))
            {
                ShowOverlay("Too late to remove", item.Name + " is already being installed.\n\n" +
                    "Stopping an installer part-way through leaves a half-installed product behind, which is the mess the leftover sweep exists to clear. Let it finish, then uninstall it.");
                return;
            }
            var handedOver = (item.Status ?? "").StartsWith("Queued for install");
            // written FIRST: the worker checks this file just before it acts on an entry
            _worker.Skip(item.Id);
            item.ProgressVis = "Collapsed";
            if (handedOver)
            {
                SetStatus(item, "Removing - waiting for the installer to skip it", "warn"); SetRing(item, "busy");
                Log(item.Name + ": removal requested - it is already queued for install, so it comes out only if the installer has not started it yet.");
            }
            else
            {
                SetStatus(item, "Removed from batch", "warn"); SetRing(item, "warn");
                Log(item.Name + " removed from the batch.");
            }
            SyncBatchStrip();
        }

        // ------------------------------------------------------------------ overlays

        private void ShowOverlay(string title, string message)
        {
            _confirmAction = null;
            BtnOverlayCancel.Visibility = Visibility.Collapsed;
            BtnOverlayOk.Content = "OK";
            TxtOverlayTitle.Text = title;
            TxtOverlayMsg.Text = message;
            Overlay.Opacity = 0;
            Overlay.Visibility = Visibility.Visible;
            Overlay.BeginAnimation(OpacityProperty, new DoubleAnimation(0, 1, new Duration(TimeSpan.FromMilliseconds(220))));
        }

        private void ShowConfirm(string title, string message, string okLabel, Action onConfirm)
        {
            ShowOverlay(title, message);
            _confirmAction = onConfirm;
            BtnOverlayOk.Content = okLabel;
            BtnOverlayCancel.Visibility = Visibility.Visible;
        }

        private void OnClosing(object sender, CancelEventArgs e)
        {
            if (!_forceClose && (_phase == "Download" || _phase == "Install"))
            {
                e.Cancel = true;
                ShowConfirm("A batch is still running",
                    "Closing now stops the downloads. An installer that has already started finishes on its own, and the elevated worker exits with this window.",
                    "Close anyway", () => { _forceClose = true; Close(); });
                return;
            }
            try { if (_dlCts != null) _dlCts.Cancel(); } catch { }
            if (_worker.Started && !_worker.EndQueued) _worker.Complete();
            AccessCode.Clear();
            try { _timer.Stop(); } catch { }
            try { _edge.Dispose(); } catch { }
            // the icon cache stays: a few kilobytes per logo, and "disk first" at the next launch
            // means the tiles are logos from the first frame instead of letters for a second
        }

        // ------------------------------------------------------------------ the log

        private void Ui(Action a)
        {
            if (Dispatcher.CheckAccess()) a(); else Dispatcher.BeginInvoke(a);
        }

        private void Log(string message)
        {
            if (!Dispatcher.CheckAccess()) { Dispatcher.BeginInvoke(new Action(() => Log(message))); return; }
            _log.Add(message);
        }

        private static string LogKind(string m)
        {
            var s = (m ?? "").ToLowerInvariant();
            if (s.Contains("fail") || s.Contains("error") || s.Contains("refused") || s.Contains("could not") || s.Contains("unreadable") || s.Contains("not enough")) return "fail";
            if (s.Contains("skipped") || s.Contains("cancel") || s.Contains("removed") || s.Contains("warning") || s.Contains("offline") || s.Contains("expired") || s.Contains("left behind")) return "warn";
            if (s.Contains("installed") || s.Contains("complete") || s.Contains("loaded") || s.Contains("downloaded")) return "ok";
            return "default";
        }

        private void OnLogLine(string ts, string message)
        {
            try
            {
                if (_logPara == null)
                {
                    _logPara = new Paragraph { Margin = new Thickness(0), LineHeight = 15 };
                    var doc = new FlowDocument(_logPara) { PagePadding = new Thickness(0), FontFamily = TxtLog.FontFamily, FontSize = TxtLog.FontSize };
                    TxtLog.Document = doc;
                }
                var kind = LogKind(message);
                var t = new Run("[" + ts + "] ") { Foreground = Brush(LogPalette["time"]) };
                var m = new Run(message) { Foreground = Brush(LogPalette[kind]) };
                if (kind == "fail") m.FontWeight = FontWeights.SemiBold;
                _logPara.Inlines.Add(t);
                _logPara.Inlines.Add(m);
                _logPara.Inlines.Add(new LineBreak());
                _logLines++;
                while (_logLines > LogMax && _logPara.Inlines.Count >= 3)
                {
                    for (int i = 0; i < 3; i++) _logPara.Inlines.Remove(_logPara.Inlines.FirstInline);
                    _logLines--;
                }
                TxtLog.ScrollToEnd();
            }
            catch { /* the log must never be the thing that breaks a deployment */ }
        }

        private string LogText()
        {
            var doc = TxtLog.Document;
            if (doc == null) return "";
            return new TextRange(doc.ContentStart, doc.ContentEnd).Text;
        }

        private void SaveLog()
        {
            try
            {
                var dlg = new Microsoft.Win32.SaveFileDialog
                {
                    FileName = "PC2Go-log-" + DateTime.Now.ToString("yyyyMMdd-HHmmss") + ".txt",
                    Filter = "Text files (*.txt)|*.txt|All files (*.*)|*.*",
                };
                if (dlg.ShowDialog(this) == true)
                {
                    var text = _log.Path != null && File.Exists(_log.Path) ? File.ReadAllText(_log.Path) : LogText();
                    File.WriteAllText(dlg.FileName, text, new UTF8Encoding(false));
                    TxtStatus.Text = "Log saved to " + dlg.FileName;
                }
            }
            catch (Exception ex) { ShowOverlay("Could not save the log", ex.Message); }
        }
    }
}
