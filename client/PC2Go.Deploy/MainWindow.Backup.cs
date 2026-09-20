using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.IO;
using System.Linq;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Interop;
using System.Windows.Media;
using PC2Go.Deploy.Models;
using PC2Go.Deploy.Services;

namespace PC2Go.Deploy
{
    /// <summary>
    /// The Data Backup tab: one engine, three destinations. The mode lives in one field rather
    /// than being inferred from which controls happen to be filled in - "work out the intent from
    /// the UI state" is how a backup ends up pointed somewhere nobody chose.
    ///   profile  - another account on this machine        (srcKind profile -> dstKind profile)
    ///   folder   - a drive, a USB stick, a share          (srcKind profile -> dstKind folder)
    ///   restore  - a backup put back into an account      (srcKind folder  -> dstKind profile)
    /// The reads (folder sizes, this PC's shares, the network sweep) are the script's own functions
    /// through the reader; the copy is the worker's `migrate` entry, field for field.
    /// </summary>
    public partial class MainWindow
    {
        private string _backupMode = "folder", _folderPath = "", _srcKind = "account", _restoreKind = "account", _restoreKindPicked = "", _restoreTo = "";
        private Dictionary<string, object> _restoreManifest;
        private string _srcPick = "", _dstPick = "";
        private bool _backupSynced, _migDefsLoaded;
        private List<string> _msaNames = new List<string>();
        private List<MigrateDef> _migDefs = new List<MigrateDef>();
        private readonly ObservableCollection<AppItem> _srcUsers = new ObservableCollection<AppItem>();
        private readonly ObservableCollection<AppItem> _dstUsers = new ObservableCollection<AppItem>();
        private readonly ObservableCollection<AppItem> _migItems = new ObservableCollection<AppItem>();
        private readonly ObservableCollection<AppItem> _srcPaths = new ObservableCollection<AppItem>();
        private readonly ObservableCollection<AppItem> _shareDrives = new ObservableCollection<AppItem>();
        private readonly ObservableCollection<AppItem> _shareFolders = new ObservableCollection<AppItem>();
        private ListCollectionView _srcView, _dstView, _migView;
        private string _netHost = "", _netPickedPath = "", _netUser = "", _netPassword = "";
        private bool _netScanning, _netSelBusy, _measuring;
        private CancellationTokenSource _netCts, _measCts;

        private void WireBackup()
        {
            _srcView = (ListCollectionView)CollectionViewSource.GetDefaultView(_srcUsers);
            _srcView.Filter = o =>
            {
                if (_backupMode != "profile") return true;
                var it = (AppItem)o;
                return !(_dstPick.Length > 0 && (it.Name ?? "") == _dstPick);
            };
            _dstView = (ListCollectionView)CollectionViewSource.GetDefaultView(_dstUsers);
            _dstView.Filter = o =>
            {
                if (_backupMode != "profile") return true;
                var it = (AppItem)o;
                if (_srcPick.Length > 0 && (it.Name ?? "") == _srcPick) return false;
                if (_srcUsers.Count == 1 && (it.Name ?? "") == (_srcUsers[0].Name ?? "")) return false;
                return true;
            };
            _migView = (ListCollectionView)CollectionViewSource.GetDefaultView(_migItems);
            _migView.GroupDescriptions.Add(new PropertyGroupDescription("Category"));
            ListSrcUsers.ItemsSource = _srcView;
            ListDstUsers.ItemsSource = _dstView;
            ListMigrate.ItemsSource = _migView;
            ListSrcPaths.ItemsSource = _srcPaths;
            ListShareDrives.ItemsSource = _shareDrives;
            ListShareFolders.ItemsSource = _shareFolders;

            BtnModeProfile.Click += (s, e) => SelectBackupMode("profile");
            BtnModeFolder.Click += (s, e) => SelectBackupMode("folder");
            BtnModeRestore.Click += (s, e) => SelectBackupMode("restore");
            BtnSrcAccounts.Click += (s, e) => { if (_srcKind != "account") { _srcKind = "account"; SyncSrcKind(); UpdateUserEmptyStates(); BuildMigrateList(); } };
            BtnSrcPaths.Click += (s, e) => { if (_srcKind != "paths") { _srcKind = "paths"; SyncSrcKind(); UpdateUserEmptyStates(); BuildMigrateList(); } };
            BtnDstAccount.Click += (s, e) => { if (TestBatchBusy()) return; _restoreKindPicked = "account"; SyncRestoreTarget(); UpdateUserEmptyStates(); UpdateDash(); };
            BtnDstFolder.Click += (s, e) => { if (TestBatchBusy()) return; _restoreKindPicked = "paths"; SyncRestoreTarget(); UpdateUserEmptyStates(); UpdateDash(); };
            BtnFolderPick.Click += (s, e) => OnFolderPick();
            BtnAddSrcPath.Click += (s, e) => OnAddSrcPath();
            BtnRestoreOrig.Click += (s, e) => { if (TestBatchBusy()) return; _restoreTo = "orig"; SyncRestoreTarget(); UpdateDash(); };
            BtnRestorePick.Click += (s, e) => OnRestorePick();
            BtnNetFind.Click += (s, e) => OnNetFind();
            BtnNetCancel.Click += (s, e) => { if (_netCts != null) _netCts.Cancel(); NetOverlay.Visibility = Visibility.Collapsed; };
            BtnNetStop.Click += (s, e) => { if (_netCts != null) _netCts.Cancel(); TxtNetStatus.Text = "Stopping..."; };
            BtnNetScan.Click += (s, e) => { var _ = StartNetScanAsync(); };
            ListNetHosts.SelectionChanged += (s, e) => { var _ = OnNetHostSelectedAsync(); };
            TreeNetShares.SelectedItemChanged += (s, e) => { var n = TreeNetShares.SelectedItem as TreeViewItem; _netPickedPath = (n != null && n.Tag is string) ? (string)n.Tag : ""; };
            TxtNetManual.TextChanged += (s, e) => HintNetManual.Visibility = TxtNetManual.Text.Length > 0 ? Visibility.Collapsed : Visibility.Visible;
            BtnNetUse.Click += (s, e) => { var _ = OnNetUseAsync(); };
            BtnShareThis.Click += (s, e) => { var _ = OnShareThisAsync(); };
            BtnShareAddFolder.Click += (s, e) => OnShareAddFolder();
            BtnShareCancel.Click += (s, e) => ShareOverlay.Visibility = Visibility.Collapsed;
            ChkShareAnyone.Checked += (s, e) => ShareNote("No password: ANY device on this network can read and write what you share. Only use this on a network you trust, and press Stop sharing when the backup is done.", "Warn");
            ChkShareAnyone.Unchecked += (s, e) => ShareNote("", "Dim");
            BtnShareOk.Click += (s, e) => { var _ = OnShareOkAsync(); };
            BtnShareStop.Click += (s, e) => { var _ = OnShareStopAsync(); };
            BtnMigrate.Click += (s, e) => { var _ = OnMigrateClickAsync(); };
        }

        /// <summary>
        /// Select-Tab 'Migrate': the mode sync FIRST and synchronously - the window's default layout
        /// has the account list in the TO column and no folder picker, and on a client machine the
        /// two reads below take seconds, so the first frame must already be the right one. Then the
        /// accounts on first visit, the item table once, the shares on every visit (they change
        /// outside this tool).
        /// </summary>
        private async Task OnBackupTabShownAsync()
        {
            try
            {
                if (!_backupSynced) { _backupSynced = true; SyncBackupMode(); }
                if (!_usersLoaded) { _usersLoaded = true; await LoadUsersAsync(); }
                if (!_migDefsLoaded)
                {
                    _migDefsLoaded = true;
                    await EnsureMigrateDefsAsync();
                    SyncBackupMode();
                    BuildMigrateList();
                }
                await SyncShareButtonsAsync();
            }
            catch (Exception ex) { Log("Data Backup: " + ex.Message); }
        }

        private async Task EnsureMigrateDefsAsync()
        {
            if (_migDefs.Count > 0) return;
            var json = await _reader.RunAsync("migratedefs", null, null, CancellationToken.None, 60);
            _migDefs = BackupList.ParseDefs(json);
        }

        /// <summary>Load-Users' SrcUsers / DstUsers / MsaNames parts, from the same accounts read.</summary>
        private void OnUsersLoaded(AccountLoad load)
        {
            // only enabled accounts can receive a migration - a disabled one cannot sign in to use it
            var accounts = load.Accounts.Where(a => a.Enabled).ToList();
            // detach both views before mutating: a bound, filtered CollectionView throws if the collection changes underneath it
            ListSrcUsers.ItemsSource = null;
            ListDstUsers.ItemsSource = null;
            _srcPick = ""; _dstPick = "";
            _srcUsers.Clear();
            foreach (var p in load.Profiles)
            {
                var acct = accounts.FirstOrDefault(a => a.Sid == p.Sid || a.Name == p.Name);
                var u = BackupList.SrcRow(p, acct, load.Me);
                u.PropertyChanged += (s, e) => { if (e.PropertyName == "IsSelected") SelectOnlyOne(_srcUsers, (AppItem)s); };
                _srcUsers.Add(u);
            }
            _dstUsers.Clear();
            foreach (var a in accounts)
            {
                var prof = load.Profiles.FirstOrDefault(p => p.Sid == a.Sid || p.Name == a.Name);
                var u = BackupList.DstRow(a, prof);
                u.PropertyChanged += (s, e) => { if (e.PropertyName == "IsSelected") SelectOnlyOne(_dstUsers, (AppItem)s); };
                _dstUsers.Add(u);
            }
            ListSrcUsers.ItemsSource = _srcView;
            ListDstUsers.ItemsSource = _dstView;
            _msaNames = accounts.Where(a => a.Kind == "Microsoft account").Select(a => a.Name).ToList();
            SyncUserHint();
            UpdateUserEmptyStates();
            BuildMigrateList();
        }

        /// <summary>Select-OnlyOne: a radio in code - unticks the others and refreshes the OPPOSITE view, whose filter reads the pick.</summary>
        private void SelectOnlyOne(ObservableCollection<AppItem> coll, AppItem chosen)
        {
            if (_userSelecting) return;
            _userSelecting = true;
            try
            {
                if (chosen.IsSelected) foreach (var x in coll) if (!ReferenceEquals(x, chosen)) x.IsSelected = false;
                var isSrc = ReferenceEquals(coll, _srcUsers);
                var pick = chosen.IsSelected ? (chosen.Name ?? "") : "";
                if (isSrc) _srcPick = pick; else _dstPick = pick;
                try { if (isSrc) _dstView.Refresh(); else _srcView.Refresh(); } catch { }
            }
            finally { _userSelecting = false; }
            UpdateUserEmptyStates();
            BuildMigrateList();
        }

        private AppItem SelectedUser(ObservableCollection<AppItem> coll) { return coll.FirstOrDefault(x => x.IsSelected); }

        // ------------------------------------------------------------------ the mode

        private void SyncBackupMode()
        {
            var on = (Style)FindResource("TabActive"); var off = (Style)FindResource("TabIdle");
            BtnModeProfile.Style = _backupMode == "profile" ? on : off;
            BtnModeFolder.Style = _backupMode == "folder" ? on : off;
            BtnModeRestore.Style = _backupMode == "restore" ? on : off;
            // the account list and the folder picker share the right-hand column; exactly one is ever visible
            PanelFolderPick.Visibility = _backupMode == "profile" ? Visibility.Collapsed : Visibility.Visible;
            switch (_backupMode)
            {
                case "folder": TxtFolderWhat.Text = ""; TxtFolderNote.Text = ""; if (!_measuring) BtnMigrate.Content = "Back Up Data"; break;
                case "restore": TxtFolderWhat.Text = ""; TxtFolderNote.Text = ""; if (!_measuring) BtnMigrate.Content = "Restore Data"; break;
                default: if (!_measuring) BtnMigrate.Content = "Copy Data"; break;
            }
            // the column headings are part of the instruction, not decoration
            switch (_backupMode)
            {
                case "folder": TxtFromTitle.Text = "Back up FROM"; TxtToTitle.Text = "Back up TO"; break;
                case "restore": TxtFromTitle.Text = "Restore FROM"; TxtToTitle.Text = "Restore INTO"; break;
                default: TxtFromTitle.Text = "Copy FROM"; TxtToTitle.Text = "Copy TO"; break;
            }
            TxtFromWhat.Text = ""; TxtToWhat.Text = "";
            // the picker MOVES between the columns: a restore's folder is the source and belongs on the left
            var want = _backupMode == "restore" ? SrcColumn : DstColumn;
            if (!ReferenceEquals(PanelFolderPick.Parent, want))
            {
                var par = PanelFolderPick.Parent as Panel;
                if (par != null) par.Children.Remove(PanelFolderPick);
                want.Children.Add(PanelFolderPick);
            }
            ListSrcUsers.Visibility = _backupMode == "restore" ? Visibility.Collapsed : Visibility.Visible;
            ListDstUsers.Visibility = _backupMode == "folder" ? Visibility.Collapsed : Visibility.Visible;
            try { _srcView.Refresh(); _dstView.Refresh(); } catch { }
            SyncSrcKind(); SyncRestoreTarget();
            SyncUserHint();
            UpdateUserEmptyStates();
            // The share buttons are NOT refreshed here. SyncBackupMode runs twice on the first tab
            // show and again on every mode radio click, and each run fired its own hidden
            // powershell.exe to list SMB shares - about 0.7 s a time, most of it the SMB module
            // load - to set two properties that the awaited read at the end of
            // OnBackupTabShownAsync then sets to the same values. Switching mode cannot change
            // what this PC shares.
            UpdateDash();
        }

        private void SelectBackupMode(string which)
        {
            if (TestBatchBusy()) return;
            if (_backupMode == which) return;
            _backupMode = which;
            // a sign-in belongs to the folder it was typed for, and the folder means a different thing in each mode - chosen again, on purpose
            _netUser = ""; _netPassword = "";
            _folderPath = "";
            TxtFolderPath.Text = "";
            TxtFolderPath.Visibility = Visibility.Collapsed;
            SyncBackupMode();
            BuildMigrateList();
        }

        /// <summary>Which source list is on screen: the kind switch only exists for a backup.</summary>
        private void SyncSrcKind()
        {
            var on = (Style)FindResource("TabActive"); var off = (Style)FindResource("TabIdle");
            var isBackup = _backupMode == "folder";
            RowSrcKind.Visibility = isBackup ? Visibility.Visible : Visibility.Collapsed;
            var paths = isBackup && _srcKind == "paths";
            BtnSrcAccounts.Style = paths ? off : on;
            BtnSrcPaths.Style = paths ? on : off;
            PanelSrcPaths.Visibility = paths ? Visibility.Visible : Visibility.Collapsed;
            if (paths) { ListSrcUsers.Visibility = Visibility.Collapsed; EmptySrc.Visibility = Visibility.Collapsed; }
            else if (_backupMode != "restore") ListSrcUsers.Visibility = Visibility.Visible;
        }

        /// <summary>WHERE a restore goes: an account, or a folder or drive; a folders-and-drives backup also offers "where it came from".</summary>
        private void SyncRestoreTarget()
        {
            var isRestore = _backupMode == "restore";
            var hasOrig = _restoreManifest != null && Json.Str(_restoreManifest, "kind") == "paths-backup";
            if (_restoreKindPicked.Length == 0) _restoreKindPicked = hasOrig ? "paths" : "account";
            _restoreKind = isRestore ? _restoreKindPicked : "account";
            var isPaths = _restoreKind == "paths";
            var on = (Style)FindResource("TabActive"); var off = (Style)FindResource("TabIdle");
            RowDstKind.Visibility = isRestore ? Visibility.Visible : Visibility.Collapsed;
            BtnDstAccount.Style = isPaths ? off : on;
            BtnDstFolder.Style = isPaths ? on : off;
            PanelRestoreTo.Visibility = (isRestore && isPaths) ? Visibility.Visible : Visibility.Collapsed;
            BtnRestoreOrig.Visibility = hasOrig ? Visibility.Visible : Visibility.Collapsed;
            if (isRestore) ListDstUsers.Visibility = isPaths ? Visibility.Collapsed : Visibility.Visible;
            if (!isPaths || (_restoreTo == "orig" && !hasOrig)) _restoreTo = "";
            TxtRestoreTo.Text = _restoreTo.Length == 0 ? "" : (_restoreTo == "orig" ? "Restore to:  where each item came from" : "Restore into:  " + _restoreTo);
            TxtRestoreTo.Visibility = _restoreTo.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
            if (isPaths) EmptyDst.Visibility = Visibility.Collapsed;
        }

        /// <summary>Only lines that carry DATA about this machine survive here.</summary>
        private void SyncUserHint()
        {
            if (_backupMode == "folder" || _backupMode == "restore" || !_acctReady) { TxtUserHint.Text = ""; return; }
            if (_dstUsers.Count <= 1) TxtUserHint.Text = "This machine has one account.";
            else if (_msaNames.Count > 0) TxtUserHint.Text = string.Join(", ", _msaNames) + " " + (_msaNames.Count == 1 ? "signs in with a Microsoft account." : "sign in with Microsoft accounts.");
            else TxtUserHint.Text = "";
        }

        private void UpdateUserEmptyStates()
        {
            var nSrc = _srcView.Count; var nDst = _dstView.Count;
            EmptyMigrate.Visibility = Visibility.Collapsed;
            // until the accounts have been read, an empty list means "not read yet", never "no profiles"
            if (!_acctReady) { EmptySrc.Visibility = Visibility.Collapsed; EmptyDst.Visibility = Visibility.Collapsed; return; }
            if (_migItems.Count == 0 && _srcPick.Length > 0 && _backupMode != "restore" && _srcKind != "paths")
            {
                EmptyMigrate.Text = "Nothing to copy from \"" + _srcPick + "\" - none of the usual data folders exist in that profile.";
                EmptyMigrate.Visibility = Visibility.Visible;
            }
            EmptySrc.Visibility = Visibility.Collapsed;
            if (nSrc == 0 && _backupMode != "restore" && !(_backupMode == "folder" && _srcKind == "paths"))
            {
                EmptySrc.Text = _dstPick.Length > 0 ? "\"" + _dstPick + "\" is the destination." : "No user profiles on this machine.";
                EmptySrc.Visibility = Visibility.Visible;
            }
            EmptyDst.Visibility = Visibility.Collapsed;
            if (nDst == 0 && _backupMode == "profile")
            {
                EmptyDst.Text = (_srcUsers.Count <= 1 || _srcPick.Length > 0) ? "No other account to copy to." : "No accounts found.";
                EmptyDst.Visibility = Visibility.Visible;
            }
            else if (nDst == 0 && _backupMode == "restore" && _restoreKind != "paths")
            {
                EmptyDst.Text = "No accounts found.";
                EmptyDst.Visibility = Visibility.Visible;
            }
        }

        /// <summary>Build-MigrateList: what can be rescued from the SOURCE - a restore lists what is in the backup, not what is on a profile.</summary>
        private void BuildMigrateList()
        {
            _migItems.Clear();
            if (_backupMode == "folder" && _srcKind == "paths") { UpdateDash(); return; }
            var root = "";
            if (_backupMode == "restore")
            {
                root = _folderPath;
                if (root.Length == 0 || !Directory.Exists(root)) { UpdateDash(); return; }
                var mf = _restoreManifest;
                if (mf != null && Json.Str(mf, "kind") == "paths-backup")
                {
                    foreach (var o in Json.Arr(mf, "items"))
                    {
                        var it = o as Dictionary<string, object>;
                        if (it == null) continue;
                        var rel = Json.Str(it, "rel");
                        if (!Directory.Exists(Path.Combine(root, rel)) && !File.Exists(Path.Combine(root, rel))) continue;
                        var bytes = Json.Long(it, "bytes");
                        var item = new AppItem
                        {
                            Id = "mig-" + rel, Name = rel, Publisher = "from " + Json.Str(it, "source"), UnArgs = rel, Size = bytes > 0 ? Format.Size(bytes) : "",
                            IsSilent = true, Category = BackupList.CatRestore, IconBg = "#FF2563EB", IconData = Catalog.IconMap["default"][0], RowOpacity = 1.0, IsSelected = true,
                        };
                        item.PropertyChanged += (s, e) => { if (e.PropertyName == "IsSelected") UpdateDash(); };
                        _migItems.Add(item);
                    }
                    UpdateDash();
                    return;
                }
            }
            else
            {
                var src = SelectedUser(_srcUsers);
                if (src == null) { UpdateDash(); return; }
                root = src.UnArgs ?? "";
            }
            if (root.Length == 0) { UpdateDash(); return; }
            foreach (var d in _migDefs)
            {
                string full;
                if (d.Abs)
                {
                    // 'abs' rows live beside the profiles, not inside one (Public); between two accounts on one PC there is nothing to copy
                    if (_backupMode == "profile") continue;
                    full = _backupMode == "restore" ? Path.Combine(root, d.Id) : Path.Combine(Path.GetDirectoryName(root) ?? root, d.Id);
                }
                else full = Path.Combine(root, d.Id);
                if (d.IsFile) { if (!File.Exists(full)) continue; }
                else if (!Directory.Exists(full)) continue;
                var item = new AppItem
                {
                    Id = "mig-" + d.Id, Name = d.Name, UnArgs = d.Id, Size = "", IsSilent = d.Safe,
                    Category = d.Safe ? BackupList.CatSafe : BackupList.CatRisky, IconBg = d.Safe ? "#FF2563EB" : "#FFF59E0B",
                    IconData = Catalog.IconMap["default"][0], RowOpacity = 1.0, IsSelected = d.Safe,
                };
                item.PropertyChanged += (s, e) => { if (e.PropertyName == "IsSelected") UpdateDash(); };
                _migItems.Add(item);
            }
            UpdateDash();
        }

        /// <summary>Update-Dash's Data Backup line: what is picked, where it goes, how many items - data only.</summary>
        private string BackupDashText()
        {
            var src = SelectedUser(_srcUsers); var dst = SelectedUser(_dstUsers);
            var n = _migItems.Count(i => i.IsSelected);
            string from;
            if (_backupMode == "restore") from = _folderPath;
            else if (_backupMode == "folder" && _srcKind == "paths") { var k = _srcPaths.Count(i => i.IsSelected); n = k; from = k > 0 ? Format.Count(k, "folder or drive", "folders and drives") : ""; }
            else from = src != null ? src.Name : "";
            string to;
            if (_backupMode == "folder") to = _folderPath;
            else if (_backupMode == "restore" && _restoreKind == "paths") to = _restoreTo == "orig" ? "where it came from" : _restoreTo;
            else to = dst != null ? dst.Name : "";
            var cnt = (_backupMode == "folder" && _srcKind == "paths") ? "" : "    |    " + Format.Count(n, "item", "items");
            if (from.Length > 0 && to.Length > 0) return from + "  ->  " + to + cnt;
            return from.Length > 0 ? from + cnt : "";
        }

        // ------------------------------------------------------------------ pickers

        private string PickFolder(string description, bool newFolderButton)
        {
            try
            {
                using (var dlg = new System.Windows.Forms.FolderBrowserDialog())
                {
                    dlg.Description = description;
                    dlg.ShowNewFolderButton = newFolderButton;
                    dlg.RootFolder = Environment.SpecialFolder.MyComputer;   // a stick is what this is usually for, so start where the drives are
                    return dlg.ShowDialog() == System.Windows.Forms.DialogResult.OK ? dlg.SelectedPath : "";
                }
            }
            catch (Exception ex) { ShowOverlay("Could not open the folder picker", ex.Message); return null; }
        }

        private void OnFolderPick()
        {
            if (TestBatchBusy()) return;
            var picked = PickFolder(_backupMode == "restore" ? "Pick the backup folder to restore from" : "Pick where the backup should be written", _backupMode != "restore");
            if (string.IsNullOrEmpty(picked)) return;
            // a locally picked folder carries no sign-in, and any left over from a network pick goes with it
            var _ = SetBackupFolderAsync(picked, "", "");
        }

        private void OnAddSrcPath()
        {
            if (TestBatchBusy()) return;
            var picked = PickFolder("Pick a folder or a whole drive to back up", false);
            if (string.IsNullOrEmpty(picked)) return;
            var why = AddSrcPath(picked);
            if (why.Length > 0) ShowOverlay("Cannot back that up", why);
        }

        private void OnRestorePick()
        {
            if (TestBatchBusy()) return;
            var picked = PickFolder("Pick the folder to restore into", true);
            if (string.IsNullOrEmpty(picked)) return;
            _restoreTo = picked; SyncRestoreTarget(); UpdateDash();
        }

        private string AddSrcPath(string path)
        {
            var why = BackupList.TestSourcePathAllowed(path);
            if (why.Length > 0) return why;
            var key = BackupList.ShareKey(path);
            if (_srcPaths.Any(x => BackupList.ShareKey(x.UnArgs) == key)) return path + " is already in the list";
            var u = BackupList.SrcPathRow(path, _srcPaths.Count + 1);
            u.PropertyChanged += (s, e) => { if (e.PropertyName == "IsSelected") UpdateDash(); };
            _srcPaths.Add(u);
            UpdateDash();
            return "";
        }

        /// <summary>Set-BackupFolder: every path the technician chooses - by picker, by scan or by typing - lands here; a share is just a directory to robocopy.</summary>
        private async Task SetBackupFolderAsync(string path, string user, string password)
        {
            // a bare drive keeps its separator: "D:" alone means "wherever the current directory on D: is"
            _folderPath = Regex.IsMatch(path ?? "", @"^[A-Za-z]:\\$") ? path : (path ?? "").TrimEnd('\\');
            _netUser = user ?? ""; _netPassword = password ?? "";
            if (_folderPath.Length == 0)
            {
                TxtFolderPath.Text = ""; TxtFolderPath.Visibility = Visibility.Collapsed; TxtFolderNote.Text = "";
                _restoreManifest = null; _restoreKindPicked = ""; _restoreTo = "";
                SyncRestoreTarget(); BuildMigrateList(); UpdateDash();
                return;
            }
            TxtFolderPath.Text = _backupMode == "restore" ? "Restore from:  " + _folderPath
                               : "Back up into:  " + _folderPath + "\\" + BackupList.BackupFolderName(_srcPick.Length > 0 ? _srcPick : "<account>");
            TxtFolderPath.Visibility = Visibility.Visible;
            if (_backupMode == "restore")
            {
                // say what is actually there, NOW: a folder without a manifest is refused by the worker anyway
                bool found = false; Dictionary<string, object> mf = null;
                try
                {
                    var json = await _reader.RunAsync("manifest", Json.Serialize(new Dictionary<string, object> { { "path", _folderPath } }), null, CancellationToken.None, 60);
                    var root = Json.ParseObject(json);
                    if (root != null) { found = Json.Bool(root, "found"); mf = root.ContainsKey("manifest") ? root["manifest"] as Dictionary<string, object> : null; }
                }
                catch (Exception ex) { Log("Backup manifest read failed: " + ex.Message); }
                if (!found)
                {
                    FolderNote("This folder has no pc2go-backup.json, so it is not a backup this tool wrote. Restoring from it will be refused.", "Bad");
                }
                else
                {
                    _restoreManifest = mf;
                    _restoreKindPicked = ""; _restoreTo = "";   // a new backup means a fresh choice of where it goes
                    SyncRestoreTarget();
                    if (mf != null)
                    {
                        var when = Json.Str(mf, "finishedUtc");
                        try { when = DateTime.Parse(when, null, System.Globalization.DateTimeStyles.RoundtripKind).ToLocalTime().ToString("d MMM yyyy, HH:mm"); } catch { }
                        FolderNote("A backup of " + Json.Str(mf, "sourceProfile") + " from " + Json.Str(mf, "sourceMachine") + ", taken " + when + ", holding " + Format.Count(Json.Arr(mf, "items").Length, "folder", "folders") + ".", "Muted");
                    }
                    else FolderNote("There is a pc2go-backup.json here but it could not be read. Restoring will be refused.", "Bad");
                }
            }
            else
            {
                var facts = BackupList.GetDiskFacts(_folderPath);
                if (facts != null)
                {
                    var v = BackupList.DiskVerdict(facts.Free, facts.Total, 0);
                    FolderNote("Disk " + facts.Name + " - " + Format.Size(facts.Free) + " free of " + Format.Size(facts.Total) + (v == "Warn" ? " - nearly full" : (v == "Bad" ? " - full" : "")) + ".", v == "Muted" ? "Muted" : v);
                }
                else if (_folderPath.StartsWith(@"\\", StringComparison.Ordinal))
                {
                    // IO.DriveInfo has no answer for a UNC path; the space check skips a destination it cannot measure rather than refusing on a made-up zero
                    FolderNote("A shared folder on " + NetShare.ShareRoot(_folderPath) + ". How much room is left on the other PC cannot be measured from here, so check it has space before starting.", "Muted");
                }
            }
            BuildMigrateList();
            UpdateDash();
        }

        private void FolderNote(string text, string brushKey) { TxtFolderNote.Text = text; TxtFolderNote.Foreground = Res(brushKey); }

        // ------------------------------------------------------------------ finding the other PC

        private void ShowNetNote(string text, string brushKey) { TxtNetNote.Text = text; TxtNetNote.Foreground = Res(brushKey); }

        private void OnNetFind()
        {
            if (TestBatchBusy()) return;
            TxtNetManual.Text = "";
            NetOverlay.Visibility = Visibility.Visible;
            // straight into it: opening this dialog has exactly one purpose
            var _ = StartNetScanAsync();
        }

        private void ResetNetLists()
        {
            ListNetHosts.Items.Clear();
            TreeNetShares.Items.Clear();
            _netHost = ""; _netPickedPath = "";
        }

        /// <summary>Start-NetScan: the sweep runs in the reader; every PC that answers lands on the list the moment it does.</summary>
        private async Task StartNetScanAsync()
        {
            if (_netScanning) return;
            _netScanning = true;
            _netCts = new CancellationTokenSource();
            ResetNetLists();
            BtnNetScan.IsEnabled = false;
            BtnNetStop.Visibility = Visibility.Visible;
            ShowNetNote("", "Dim");
            NetSpinner.Visibility = Visibility.Visible;
            TxtNetStatus.Text = "Checking your network...";
            var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            var stopped = false;
            var found = 0;
            Action<string, string> addHost = (ip, name) =>
            {
                if (!seen.Add(ip)) return;
                var named = name.Length > 0 && name != ip;
                ListNetHosts.Items.Add(new NetHostRow { Title = named ? name : ip, Sub = named ? ip : "no name - this PC did not give one", Name = name, Ip = ip });
            };
            try
            {
                var json = await _reader.RunAsync("netscan", null, text => Dispatcher.BeginInvoke(new Action(() =>
                {
                    foreach (var line in (text ?? "").Split('\n'))
                    {
                        var parts = line.Trim().Split('|');
                        if (parts.Length >= 4 && parts[0] == "P")
                        {
                            int done, total, hits;
                            int.TryParse(parts[1], out done); int.TryParse(parts[2], out total); int.TryParse(parts[3], out hits);
                            var pct = total > 0 ? (int)(100.0 * done / total) : 0;
                            TxtNetStatus.Text = "Checking your network - " + pct + "%" + (hits > 0 ? "   (" + hits + " found so far)" : "");
                        }
                        else if (parts.Length >= 3 && parts[0] == "H") addHost(parts[1], parts[2]);
                    }
                })), _netCts.Token, 600);
                var root = Json.ParseObject(json);
                if (root != null)
                    foreach (var o in Json.Arr(root, "hosts"))
                    {
                        var h = o as Dictionary<string, object>;
                        if (h != null) addHost(Json.Str(h, "Ip"), Json.Str(h, "Name"));
                    }
                found = ListNetHosts.Items.Count;
            }
            catch (OperationCanceledException) { stopped = true; }
            catch (Exception ex) { ShowNetNote("The scan could not run: " + ex.Message, "Bad"); }
            finally
            {
                _netScanning = false;
                BtnNetScan.IsEnabled = true;
                BtnNetStop.Visibility = Visibility.Collapsed;
                NetSpinner.Visibility = Visibility.Collapsed;
            }
            if (stopped) TxtNetStatus.Text = "Stopped - " + Format.Count(ListNetHosts.Items.Count, "PC", "PCs") + " found so far";
            else if (found == 0)
            {
                TxtNetStatus.Text = "No PCs answered";
                ShowNetNote("Nothing on this network accepted a file-sharing connection. That is normal if the other PC is asleep, is on a different network, or has not shared a folder yet. You can still type its name in below.", "Muted");
            }
            else
            {
                TxtNetStatus.Text = Format.Count(found, "PC", "PCs") + " found";
                ShowNetNote("Pick a PC to see the folders it shares.", "Dim");
            }
            // the scan only ever looks at THIS machine's networks
            if (!stopped && ListNetHosts.Items.Count < 2) TxtNetStatus.Text += "   (only this network was checked)";
        }

        /// <summary>Dropping the highlight is what makes the next click a change again (SelectionChanged only fires on a CHANGE).</summary>
        private void ClearNetHostPick()
        {
            _netSelBusy = true;
            try { ListNetHosts.SelectedIndex = -1; } catch { }
            _netSelBusy = false;
        }

        private sealed class ConnTry { public int Rc; public string Why = ""; }

        /// <summary>Connect-ShareInteractive: connect, and ask for a sign-in only if the far end actually demands one - 5 and 1326, nothing else.</summary>
        private async Task<ShareConn> ConnectInteractiveAsync(string path)
        {
            var res = new ShareConn();
            var root = NetShare.ShareRoot(path);
            if (root.Length == 0) { res.Ok = true; return res; }   // a local path: nothing to connect
            var machine = NetShare.Machine(root);
            Func<string, string, Task<ConnTry>> tryConnect = (u, p) => Task.Run(() => { int rc; var why = NetShare.Connect(path, u, p, out rc); return new ConnTry { Rc = rc, Why = why }; });
            var t = await tryConnect("", "");
            if (t.Why.Length == 0) { res.Ok = true; return res; }
            if (t.Rc == 1219)
            {
                // one identity per server: the existing session as somebody else has to go first
                await Task.Run(() => NetShare.Disconnect(path));
                t = await tryConnect("", "");
                if (t.Why.Length == 0) { res.Ok = true; return res; }
            }
            if (t.Rc != 5 && t.Rc != 1326) { res.Why = t.Why; return res; }
            var authErr = 0;
            for (int attempt = 1; attempt <= 3; attempt++)
            {
                string user, pw;
                var hwnd = new WindowInteropHelper(this).Handle;
                var got = NetShare.PromptCredential(hwnd, root, authErr, out user, out pw);
                res.Prompted = true;
                if (!got) { res.Why = ""; return res; }   // cancelled: not an error, just a no
                var who = NetShare.ResolveShareUser(user, machine);
                t = await tryConnect(who, pw);
                if (t.Why.Length == 0) { res.Ok = true; res.User = who; res.Password = pw; return res; }
                res.Why = t.Why;
                if (t.Rc != 5 && t.Rc != 1326) return res;
                authErr = 1326;   // so the dialog says "The user name or password is incorrect" in its own words
            }
            return res;
        }

        private TreeViewItem NewNetNode(string glyph, Brush brush, string name, string sub, string path, bool mayHaveChildren)
        {
            var sp = new StackPanel { Orientation = Orientation.Horizontal };
            sp.Children.Add(new TextBlock { Text = glyph, FontFamily = new FontFamily("Segoe MDL2 Assets"), FontSize = 16, Foreground = brush, Margin = new Thickness(0, 0, 8, 0), VerticalAlignment = VerticalAlignment.Center });
            sp.Children.Add(new TextBlock { Text = name, FontSize = 12, VerticalAlignment = VerticalAlignment.Center });
            if (!string.IsNullOrEmpty(sub))
                sp.Children.Add(new TextBlock { Text = sub, FontSize = 10.5, Foreground = Res("Dim"), Margin = new Thickness(9, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center });
            var node = new TreeViewItem { Header = sp, Tag = path };
            // a placeholder child gives the node its expander arrow before anything has been read - and marks "not filled in yet"
            if (mayHaveChildren) node.Items.Add("...");
            return node;
        }

        /// <summary>Fills a node in the first time it is opened; the placeholder check is the guard against the bubbled Expanded event.</summary>
        private void ExpandNetNode(TreeViewItem node)
        {
            if (node == null) return;
            if (node.Items.Count != 1 || !(node.Items[0] is string)) return;
            var path = node.Tag as string ?? "";
            node.Items.Clear();
            if (path.Length == 0) return;
            string[] kids;
            try { kids = Directory.GetDirectories(path).OrderBy(k => Path.GetFileName(k), StringComparer.OrdinalIgnoreCase).ToArray(); }
            catch
            {
                // a folder that will not open earns a row of its own - nothing would read as "this folder is empty"
                node.Items.Add(NewNetNode("", Res("Dim"), "cannot open this folder", "", "", false));
                return;
            }
            const int cap = 400;
            foreach (var k in kids.Take(cap))
            {
                var child = NewNetNode("", Brush("#FFE3B341"), Path.GetFileName(k), "", k, true);
                child.Expanded += (s, e) => ExpandNetNode(child);
                node.Items.Add(child);
            }
            if (kids.Length > cap) node.Items.Add(NewNetNode("", Res("Dim"), Format.Count((kids.Length - cap), "more folder", "more folders") + " not listed", "", "", false));
        }

        private async Task OnNetHostSelectedAsync()
        {
            if (_netSelBusy) return;
            TreeNetShares.Items.Clear();
            _netPickedPath = "";
            var sel = ListNetHosts.SelectedItem as NetHostRow;
            if (sel == null) return;
            // the name where there is one: a UNC built on the name survives a new DHCP address tomorrow
            _netHost = sel.Name.Length > 0 ? sel.Name : sel.Ip;
            TxtNetStatus.Text = "Connecting to " + _netHost + "...";
            ShowNetNote("", "Dim");
            // connect for real before asking what it shares: IPC$ establishes the session the enumeration runs under
            var conn = await ConnectInteractiveAsync(@"\\" + _netHost + @"\IPC$");
            if (!conn.Ok)
            {
                TxtNetStatus.Text = "";
                ClearNetHostPick();
                if (conn.Prompted && conn.Why.Length == 0) ShowNetNote(_netHost + " is there and asked for a sign-in, which was cancelled. Click it again to have another go.", "Muted");
                else ShowNetNote(conn.Why + "  Click it again to retry.", "Bad");
                return;
            }
            // kept for the job itself: the worker runs elevated, as a different account, and holds none of this session's connections
            _netUser = conn.User; _netPassword = conn.Password;
            TxtNetStatus.Text = "Asking " + _netHost + " what it shares...";
            bool ok = false; var shares = new List<string>();
            try
            {
                var json = await _reader.RunAsync("hostshares", Json.Serialize(new Dictionary<string, object> { { "host", _netHost } }), null, CancellationToken.None, 120);
                var root = Json.ParseObject(json);
                if (root != null) { ok = Json.Bool(root, "ok"); shares = Json.Strings(root, "shares").ToList(); }
            }
            catch (Exception ex) { Log("Share list of " + _netHost + " failed: " + ex.Message); }
            TxtNetStatus.Text = "";
            if (!ok)
            {
                ClearNetHostPick();
                ShowNetNote(_netHost + " is connected, but would not say what it shares. The sign-in used may not be allowed to list them. Click it again to retry, or type the folder path in below if you know its name.", "Bad");
                return;
            }
            var rootNode = NewNetNode("", Res("Lift"), _netHost, "", "", false);
            foreach (var s in shares)
            {
                // a share whose name is a single letter is almost always a whole drive somebody shared
                var isDrive = s.Length <= 2 && Regex.IsMatch(s, "^[A-Za-z]");
                var unc = @"\\" + _netHost + @"\" + s;
                var node = NewNetNode(isDrive ? "" : "", Brush("#FFE3B341"), s, unc, unc, true);
                node.Expanded += (s2, e2) => ExpandNetNode(node);
                rootNode.Items.Add(node);
            }
            rootNode.IsExpanded = true;
            TreeNetShares.Items.Add(rootNode);
            if (shares.Count == 0)
            {
                ClearNetHostPick();
                ShowNetNote(_netHost + " answered, and is genuinely not sharing a folder. Share one on that PC, or back up to a USB stick instead.", "Muted");
            }
            else
            {
                var who = (conn.User ?? "").Trim().Trim('\\');
                var signed = conn.Prompted && who.Length > 0 ? "Signed in as " + who + ".  " : (conn.Prompted ? "Signed in.  " : "Connected, no sign-in needed.  ");
                ShowNetNote(signed + Format.Count(shares.Count, "share", "shares") + ". Open one to pick a folder inside it - a share is often a whole drive, and the root of somebody's drive is rarely where a backup belongs.", "Dim");
            }
        }

        private async Task OnNetUseAsync()
        {
            if (_netScanning) return;
            // typed beats picked
            var path = (TxtNetManual.Text ?? "").Trim();
            if (path.Length == 0) path = _netPickedPath;
            if (path.Length == 0) { ShowNetNote("Pick a PC, then a share or a folder inside it. Or type a path like \\\\PC-NAME\\SharedFolder below.", "Bad"); return; }
            if (!path.StartsWith(@"\\", StringComparison.Ordinal)) { ShowNetNote("A folder on another PC starts with two backslashes, like \\\\PC-NAME\\SharedFolder.", "Bad"); return; }
            if (NetShare.ShareRoot(path).Length == 0) { ShowNetNote("That path names a PC but no folder on it. It needs both, like \\\\PC-NAME\\SharedFolder.", "Bad"); return; }
            // prove it works NOW: a wrong password caught here costs a retype, caught in the worker costs a failed batch three gigabytes in
            ShowNetNote("Checking...", "Dim");
            var conn = await ConnectInteractiveAsync(path);
            if (!conn.Ok)
            {
                if (conn.Prompted && conn.Why.Length == 0) ShowNetNote(NetShare.ShareRoot(path) + " asked for a sign-in, which was cancelled.", "Muted");
                else ShowNetNote(conn.Why, "Bad");
                return;
            }
            var exists = await Task.Run(() => Directory.Exists(path));
            if (!exists) { ShowNetNote(NetShare.ShareRoot(path) + " answered, but " + path + " is not there. Check the spelling.", "Bad"); return; }
            // a sign-in given for THIS path wins; one captured for a DIFFERENT host is not reused at all
            var pathHost = NetShare.Machine(NetShare.ShareRoot(path));
            var sameHost = _netHost.Length > 0 && pathHost.Length > 0 && string.Equals(pathHost, _netHost, StringComparison.OrdinalIgnoreCase);
            var user = conn.Prompted ? conn.User : (sameHost ? _netUser : "");
            var pw = conn.Prompted ? conn.Password : (sameHost ? _netPassword : "");
            await SetBackupFolderAsync(path, user, pw);
            NetOverlay.Visibility = Visibility.Collapsed;
        }

        // ------------------------------------------------------------------ Share this PC

        private void ShareNote(string text, string brushKey) { TxtShareNote.Text = text; TxtShareNote.Foreground = Res(brushKey); }

        private async Task<List<ShareInfo>> ReadSharesAsync()
        {
            var json = await _reader.RunAsync("shares", null, null, CancellationToken.None, 120);
            return BackupList.ParseShares(json);
        }

        /// <summary>Sync-ShareButtons: Stop only exists while this tool has shares to remove, and the hint under the folder box says what the OTHER PC has to do.</summary>
        private async Task SyncShareButtonsAsync()
        {
            List<ShareInfo> mine;
            try { mine = (await ReadSharesAsync()).Where(s => s.Description == BackupList.ShareTag).ToList(); }
            catch (Exception ex) { Log("Share list failed: " + ex.Message); return; }
            BtnShareThis.Content = mine.Count > 0 ? "Share more..." : "Share this PC";
            BtnShareStop.Visibility = mine.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
            if (mine.Count > 0 && _folderPath.Length == 0 && _backupMode != "restore")
            {
                var names = string.Join(", ", mine.Select(m => "\"" + m.Name + "\""));
                FolderNote("This PC is sharing " + names + " as \\\\" + Environment.MachineName + ". On the other PC press Network..., pick " + Environment.MachineName +
                           " and sign in as " + Environment.MachineName + "\\" + Environment.UserName + ".", "Muted");
            }
        }

        private async Task OnShareThisAsync()
        {
            if (TestBatchBusy()) return;
            ListShareDrives.ItemsSource = null; ListShareFolders.ItemsSource = null;
            _shareDrives.Clear(); _shareFolders.Clear();
            foreach (var r in BackupList.ShareCandidates()) _shareDrives.Add(r);
            ListShareDrives.ItemsSource = _shareDrives; ListShareFolders.ItemsSource = _shareFolders;
            EmptyShareFolders.Visibility = Visibility.Visible;
            ChkShareAnyone.IsChecked = false;
            // the dialog opens NOW; the share list (a few seconds in the reader) fills in behind it
            TxtShareIntro.Text = "\\\\" + Environment.MachineName + "  ·  sign in as " + Environment.MachineName + "\\" + Environment.UserName;
            ShareNote("Reading what this PC already shares...", "Dim");
            FadeIn(ShareOverlay);
            var mine = new List<ShareInfo>();
            try { mine = (await ReadSharesAsync()).Where(s => s.Description == BackupList.ShareTag).ToList(); } catch { }
            if (mine.Count > 0) TxtShareIntro.Text += "  ·  already shared: " + string.Join(", ", mine.Select(m => m.Name));
            if (TxtShareNote.Text == "Reading what this PC already shares...") ShareNote("", "Dim");
        }

        private void OnShareAddFolder()
        {
            string picked;
            try
            {
                using (var dlg = new System.Windows.Forms.FolderBrowserDialog())
                {
                    dlg.Description = "Pick a folder to share with the other PC";
                    dlg.ShowNewFolderButton = true;
                    dlg.RootFolder = Environment.SpecialFolder.MyComputer;
                    picked = dlg.ShowDialog() == System.Windows.Forms.DialogResult.OK ? dlg.SelectedPath : "";
                }
            }
            catch (Exception ex) { ShareNote("Could not open the folder picker: " + ex.Message, "Bad"); return; }
            if (string.IsNullOrEmpty(picked)) return;
            var why = AddShareFolder(picked);
            if (why.Length > 0) ShareNote(why, "Bad"); else ShareNote(picked + " added.", "Dim");
        }

        private string AddShareFolder(string path)
        {
            var why = BackupList.TestSharePathAllowed(path, _cacheDir);
            if (why.Length > 0) return why;
            var key = BackupList.ShareKey(path);
            // a drive root belongs in the drives list - tick it there instead
            var drv = _shareDrives.FirstOrDefault(d => BackupList.ShareKey(d.UnArgs) == key);
            if (drv != null) { drv.IsSelected = true; return ""; }
            if (_shareFolders.Any(f => BackupList.ShareKey(f.UnArgs) == key)) return path + " is already in the list";
            _shareFolders.Add(BackupList.ShareFolderRow(path, _shareFolders.Count + 1));
            EmptyShareFolders.Visibility = Visibility.Collapsed;
            return "";
        }

        private sealed class ShareItem { public string Path, Name; }

        private async Task OnShareOkAsync()
        {
            if (TestBatchBusy()) return;
            var picked = _shareDrives.Concat(_shareFolders).Where(i => i.IsSelected).ToList();
            if (picked.Count == 0) { ShareNote("Tick at least one drive, or add a folder.", "Bad"); return; }
            // names are decided here for the row labels; the worker decides for real against the live list
            ShareNote("Checking the share list...", "Dim");
            List<ShareInfo> all;
            try { all = await ReadSharesAsync(); } catch (Exception ex) { ShareNote("The share list could not be read: " + ex.Message, "Bad"); return; }
            var taken = all.Select(s => s.Name).ToList();
            var items = new List<ShareItem>(); var already = new List<string>();
            foreach (var p in picked)
            {
                var path = p.UnArgs ?? "";
                var key = BackupList.ShareKey(path);
                var have = all.FirstOrDefault(s => BackupList.ShareKey(s.Path) == key);
                if (have != null) { already.Add(path + " (already shared as \"" + have.Name + "\")"); continue; }
                var name = BackupList.ShareName(path, taken);
                taken.Add(name);
                items.Add(new ShareItem { Path = path, Name = name });
            }
            if (items.Count == 0)
            {
                ShareNote("Everything ticked is already shared: " + string.Join(", ", already) + ". The other PC can use those as they are.", "Warn");
                return;
            }
            var anyone = ChkShareAnyone.IsChecked == true;
            ShareOverlay.Visibility = Visibility.Collapsed;
            if (already.Count > 0) Log("Share this PC: skipped " + string.Join(", ", already));
            StartShareBatch("shareon", items, new List<string>(), anyone);
        }

        private async Task OnShareStopAsync()
        {
            if (TestBatchBusy()) return;
            TxtBusy.Text = "Reading what this PC shares...";
            BusyOverlay.Visibility = Visibility.Visible;
            List<ShareInfo> mine;
            try { mine = (await ReadSharesAsync()).Where(s => s.Description == BackupList.ShareTag).ToList(); }
            catch (Exception ex) { BusyOverlay.Visibility = Visibility.Collapsed; ShowOverlay("Could not read the shares", ex.Message); return; }
            finally { BusyOverlay.Visibility = Visibility.Collapsed; }
            if (mine.Count == 0) { await SyncShareButtonsAsync(); return; }
            var names = mine.Select(m => m.Name).ToList();
            ShowConfirm("Stop sharing?",
                "These shares this tool created will be removed. The files themselves are not touched.\n\n" +
                string.Join("\n", mine.Select(m => "  - " + m.Name + "  ->  " + m.Path)) +
                "\n\nIf nothing else on this PC is shared, file sharing is turned back off as well. A share the other PC is still copying into is left in place and reported.",
                "Continue", () => StartShareBatch("shareoff", new List<ShareItem>(), names, false));
        }

        /// <summary>Start-ShareBatch: several elevated steps behind ONE UAC prompt - setup then one row per share, or one row per share then the tear-down.</summary>
        private void StartShareBatch(string action, List<ShareItem> items, List<string> names, bool anyone)
        {
            var rows = new List<AppItem>(); var entries = new List<Dictionary<string, object>>();
            if (action == "shareon")
            {
                rows.Add(new AppItem { Id = "share-setup", Name = "Turn on file sharing" });
                entries.Add(new Dictionary<string, object> { { "id", "share-setup" }, { "action", "sharesetup" }, { "chain", true }, { "anyone", anyone } });
                var i = 0;
                foreach (var it in items)
                {
                    i++;
                    rows.Add(new AppItem { Id = "share-" + i, Name = "Share " + it.Path + " as \"" + it.Name + "\"" });
                    entries.Add(new Dictionary<string, object> { { "id", "share-" + i }, { "action", "shareon" }, { "chain", true }, { "path", it.Path }, { "name", it.Name }, { "anyone", anyone } });
                }
            }
            else
            {
                var i = 0;
                foreach (var n in names)
                {
                    i++;
                    rows.Add(new AppItem { Id = "share-" + i, Name = "Stop sharing \"" + n + "\"" });
                    entries.Add(new Dictionary<string, object> { { "id", "share-" + i }, { "action", "shareoff" }, { "name", n } });
                }
                rows.Add(new AppItem { Id = "share-down", Name = "Turn file sharing back off if nothing else is shared" });
                entries.Add(new Dictionary<string, object> { { "id", "share-down" }, { "action", "sharedown" } });
            }
            foreach (var r in rows)
            {
                r.Category = "Sharing"; r.IconBg = "#FF2563EB"; r.IconData = Catalog.IconMap["default"][0]; r.RowOpacity = 1.0;
                SetStatus(r, "Queued", "neutral"); SetRing(r, "queued");
            }
            _pending = rows;
            _batchTab = "Share";
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
            BtnMigrate.IsEnabled = false; BtnInstall.IsEnabled = false;
            BtnShareThis.IsEnabled = false; BtnShareStop.IsEnabled = false;
            TxtNow.Text = rows[0].Name;
            DotNow.Fill = Brush("#FF4C8DFF");
            TxtStatus.Text = action == "shareon" ? "Turning on file sharing..." : "Removing shares...";
            Log("Sharing: " + action + " for " + Format.Count((action == "shareon" ? items.Count : names.Count), "item", "items") + " - started.");
            UpdateDash();
        }

        // ------------------------------------------------------------------ the copy

        private async Task OnMigrateClickAsync()
        {
            // a second press while measuring IS the stop
            if (_measuring) { if (_measCts != null) _measCts.Cancel(); BtnMigrate.IsEnabled = false; return; }
            if (TestBatchBusy()) return;
            var mode = _backupMode;
            AppItem src = null;
            var pathsKind = mode == "folder" && _srcKind == "paths";
            var srcPaths = new List<AppItem>();
            if (pathsKind)
            {
                srcPaths = _srcPaths.Where(p => p.IsSelected).ToList();
                if (srcPaths.Count == 0) { ShowOverlay("Nothing to back up", "Add a folder or a drive on the left, or tick one that is already there."); return; }
                foreach (var p in srcPaths)
                {
                    var why = BackupList.TestSourcePathAllowed(p.UnArgs ?? "");
                    if (why.Length > 0) { ShowOverlay("Cannot back that up", why); return; }
                }
            }
            else if (mode != "restore")
            {
                src = SelectedUser(_srcUsers);
                if (src == null) { ShowOverlay("No source", "Pick the account to copy FROM in the left column."); return; }
            }
            string srcKind = "profile", dstKind = "profile", dstPath = "", dstUser = "", restoreTo = "";
            var srcRoot = src != null ? (src.UnArgs ?? "") : "";
            AppItem dst = null;
            switch (mode)
            {
                case "folder":
                {
                    if (_folderPath.Length == 0) { ShowOverlay("No folder chosen", "Choose the folder to back up to."); return; }
                    if (!Directory.Exists(_folderPath))
                    {
                        ShowOverlay("Folder not there", _folderPath + " cannot be reached any more.\n\nIf it is a USB stick, check it is still plugged in. If it is another PC, check it is awake and on this network. Then choose it again.");
                        return;
                    }
                    // what was picked is the PARENT; the backup lands in its own folder inside it
                    dstKind = "folder";
                    dstPath = Path.Combine(_folderPath, BackupList.BackupFolderName(pathsKind ? "folders and drives" : src.Name));
                    var roots = pathsKind ? srcPaths.Select(p => p.UnArgs ?? "").ToList() : new List<string> { srcRoot };
                    var dk = BackupList.ShareKey(_folderPath);
                    foreach (var r in roots)
                    {
                        var sk = BackupList.ShareKey(r);
                        if (sk.Length > 0 && dk.Length > 0 && (dk == sk || dk.StartsWith(sk + "\\", StringComparison.Ordinal)))
                        {
                            ShowOverlay("Refused - the backup would be inside what it copies", _folderPath + " is inside " + r + ".\n\nCopying a folder into itself grows without limit until the disk fills. Pick somewhere outside it - another drive, a stick, or another PC.");
                            return;
                        }
                        if (sk.Length > 0 && dk.Length > 0 && sk.StartsWith(dk + "\\", StringComparison.Ordinal))
                        {
                            ShowOverlay("Refused - that folder contains what it would copy", _folderPath + " contains " + r + ", so the copy would include its own destination.\n\nPick a folder that is not a parent of it.");
                            return;
                        }
                    }
                    break;
                }
                case "restore":
                {
                    if (_folderPath.Length == 0) { ShowOverlay("No backup chosen", "Choose the backup folder to restore from."); return; }
                    if (!Directory.Exists(_folderPath))
                    {
                        ShowOverlay("Backup not there", _folderPath + " cannot be reached any more.\n\nIf it is on a USB stick, check it is still plugged in. If it is on another PC, check it is awake. Then choose it again.");
                        return;
                    }
                    if (!File.Exists(Path.Combine(_folderPath, "pc2go-backup.json")))
                    {
                        ShowOverlay("Not a backup this tool wrote",
                            _folderPath + " has no pc2go-backup.json in it, so there is no record of where it came from or what it holds.\n\n" +
                            "Restoring from an unknown folder could pour anything over a profile, so it is refused. Pick the folder a backup was written INTO - it is named \"PC2Go Backup - <PC> - <account>\".");
                        return;
                    }
                    srcKind = "folder"; srcRoot = _folderPath;   // roots swapped: the backup is the source
                    if (_restoreKind == "paths")
                    {
                        if (_restoreTo.Length == 0) { ShowOverlay("Nowhere to restore to", "Choose the folder to restore into."); return; }
                        if (_restoreTo != "orig" && !Directory.Exists(_restoreTo)) { ShowOverlay("Folder not there", _restoreTo + " cannot be reached any more. Choose it again."); return; }
                        dstKind = "paths"; restoreTo = _restoreTo; dstPath = restoreTo == "orig" ? "" : restoreTo;
                    }
                    else
                    {
                        dst = SelectedUser(_dstUsers);
                        if (dst == null) { ShowOverlay("No destination", "Pick the account to restore INTO in the right-hand column."); return; }
                        dstKind = "profile"; dstPath = dst.UnArgs ?? ""; dstUser = dst.DetectPath ?? "";
                    }
                    break;
                }
                default:
                {
                    dst = SelectedUser(_dstUsers);
                    if (dst == null) { ShowOverlay("No destination", "Pick the account to copy TO in the right-hand column."); return; }
                    if (src.DetectPath == dst.DetectPath || src.Name == dst.Name) { ShowOverlay("Same account", "The source and destination are the same profile. Pick two different accounts."); return; }
                    dstPath = dst.UnArgs ?? ""; dstUser = dst.DetectPath ?? "";
                    break;
                }
            }
            var sel = pathsKind ? srcPaths : _migItems.Where(i => i.IsSelected).ToList();
            if (sel.Count == 0) { ShowOverlay("Nothing selected", "Tick at least one folder to copy."); return; }

            // measure before promising anything: a profile copy is the one operation here that can fill the disk
            _measuring = true;
            _measCts = new CancellationTokenSource();
            var btnText = BtnMigrate.Content;
            BtnMigrate.Content = "Stop measuring";
            TxtNow.Text = "Measuring...";
            DotNow.Fill = Brush("#FF4C8DFF");
            RowNow.Visibility = Visibility.Visible;
            var t0 = DateTime.Now;
            long total = 0; var stopped = false; var count = sel.Count;
            var labels = sel.Select(m => m.Name).ToList();
            var paths = sel.Select(m => pathsKind ? (m.UnArgs ?? "")
                                        : ((m.UnArgs == "Public" && mode != "restore") ? Path.Combine(Path.GetDirectoryName(srcRoot) ?? srcRoot, "Public") : Path.Combine(srcRoot, m.UnArgs ?? ""))).ToList();
            try
            {
                var json = await _reader.RunAsync("foldersize", Json.Serialize(new Dictionary<string, object> { { "paths", paths } }), text => Dispatcher.BeginInvoke(new Action(() =>
                {
                    var parts = (text ?? "").Trim().Split('|');
                    if (parts.Length < 3) return;
                    int i; long running, sofar;
                    if (!int.TryParse(parts[0], out i) || !long.TryParse(parts[1], out running) || !long.TryParse(parts[2], out sofar)) return;
                    if (i < 1 || i > labels.Count) return;
                    TxtNow.Text = "Measuring " + labels[i - 1] + "  (" + (i - 1) + " of " + count + ")  -  " + Format.Size(running + sofar) + " so far   -   press Stop measuring to skip this";
                })), _measCts.Token, 7200);
                var root = Json.ParseObject(json);
                var sizes = root != null ? Json.Arr(root, "sizes") : new object[0];
                for (int k = 0; k < sel.Count && k < sizes.Length; k++)
                {
                    var sz = Convert.ToInt64(sizes[k]);
                    sel[k].Size = Format.Size(sz);
                    total += sz;
                }
                TxtNow.Text = "Measured " + sel.Count + " of " + sel.Count + "  -  " + Format.Size(total) + " so far";
            }
            catch (OperationCanceledException) { stopped = true; }
            catch (Exception ex)
            {
                _measuring = false; BtnMigrate.Content = btnText; BtnMigrate.IsEnabled = true; RowNow.Visibility = Visibility.Collapsed;
                ShowOverlay("Could not measure", "The folders could not be measured, so nothing was promised.\n\n" + ex.Message);
                UpdateDash();
                return;
            }
            finally
            {
                _measuring = false;
                BtnMigrate.Content = btnText;
                BtnMigrate.IsEnabled = true;
                RowNow.Visibility = Visibility.Collapsed;
            }
            var secs = (int)(DateTime.Now - t0).TotalSeconds;
            if (stopped)
            {
                Log("Measuring stopped by technician after " + Format.Elapsed(secs) + " - nothing was copied. Press the button again to start over.");
                UpdateDash();
                return;
            }
            Log((mode == "restore" ? "Restore" : "Backup") + ": measured " + Format.Count(sel.Count, "item", "items") + (pathsKind ? "" : " under " + srcRoot) + " - " + Format.Size(total) + " in " + Format.Elapsed(secs) + ".");
            UpdateDash();

            // the DESTINATION drive, not the system drive; a UNC destination measures 0 and is skipped, not refused
            var dstRoot = dstPath;
            if (dstRoot.Length == 0 && dst != null) dstRoot = dst.UnArgs ?? "";
            if (dstRoot.Length == 0 && restoreTo == "orig" && _restoreManifest != null)
            {
                var first = Json.Arr(_restoreManifest, "items").FirstOrDefault() as Dictionary<string, object>;
                if (first != null) dstRoot = Json.Str(first, "source");
            }
            if (dstRoot.Length == 0) dstRoot = Path.GetDirectoryName(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile)) ?? "";
            long free = 0;
            try { free = new DriveInfo(Path.GetPathRoot(Path.GetFullPath(dstRoot))).AvailableFreeSpace; } catch { free = 0; }
            if (free > 0 && free < total * 1.1)
            {
                ShowOverlay("Not enough disk space", "This copy needs " + Format.Size(total) + " plus headroom, but only " + Format.Size(free) + " is free.\n\nNothing is moved or deleted by this tool, so both copies have to fit.");
                return;
            }

            var risky = sel.Count(i => !i.IsSilent);
            var fromTxt = pathsKind ? string.Join("\n  ", srcPaths.Select(p => p.UnArgs)) : srcRoot;
            string toTxt;
            if (mode == "folder") toTxt = dstPath;
            else if (dstKind == "paths") toTxt = restoreTo == "orig" ? "where each item came from" : restoreTo;
            else toTxt = "the profile of \"" + dst.Name + "\"";
            var verb = mode == "restore" ? "Restore" : "Copy";
            var msg = verb + " " + Format.Count(sel.Count, "item", "items") + ", " + Format.Size(total) + ", from\n  " + fromTxt + "\nto\n  " + toTxt + ".\n\n" +
                      (mode == "restore"
                          ? "The backup is left completely untouched - this copies out of it, it never moves.\n" +
                            "Files already in the account with the same size and date are left alone, and a file the account has changed since the backup is kept rather than rolled back.\n"
                          : "The source profile is left completely untouched - this copies, it never moves.\n");
            if (mode == "folder") msg += "Running this again later copies only what has changed; nothing already on the drive is deleted.\n";
            if (_netUser.Length > 0) msg += "The other PC will be signed into as " + _netUser + ".\n";
            msg += "You can press Cancel on the progress row while it copies - the folder in flight is stopped, and what was already copied stays.\n";
            if (risky > 0) msg += "\n" + risky + " of these come from AppData. If the old profile is corrupt, the fault often lives there and can travel with them.";

            var items = pathsKind ? new string[0] : sel.Select(i => i.UnArgs ?? "").ToArray();
            var pathList = pathsKind ? srcPaths.Select(p => p.UnArgs ?? "").ToArray() : new string[0];
            if (pathsKind) srcKind = "paths";
            var data = new Dictionary<string, object>
            {
                { "src", srcRoot }, { "srcKind", srcKind }, { "paths", pathList }, { "restoreTo", restoreTo }, { "dstUser", dstUser }, { "dstPath", dstPath }, { "dstKind", dstKind },
                // empty for a local folder or another profile; netPassword is DPAPI-wrapped on the way out
                { "netUser", _netUser }, { "netPassword", _netPassword }, { "items", items },
            };
            var title = mode == "restore" ? "Restore this backup?" : (mode == "folder" ? "Back up this data?" : "Copy this data?");
            ShowConfirm(title, msg, "Continue", () => StartUserBatch("migrate", data));
        }

        /// <summary>
        /// Finish-Batch's Migrate/Share parts: the buttons come back, a share batch re-reads the
        /// shares, a migration re-reads the accounts (it creates the destination profile folder),
        /// and the closing sheet says per row what the worker wrote - plus, after a share that
        /// worked, exactly what to press and type on the other PC.
        /// </summary>
        private void OnBatchEndedBackup(string summary, int done, int fail, int cans)
        {
            BtnMigrate.IsEnabled = true;
            BtnShareThis.IsEnabled = true; BtnShareStop.IsEnabled = true;
            if (_batchTab != "Migrate" && _batchTab != "Share") return;
            if (_batchTab == "Share") { var _ = SyncShareButtonsAsync(); }
            if (_batchTab == "Migrate")
            {
                TxtNewUser.Clear(); TxtNewFull.Clear(); TxtNewPw.Clear(); TxtActPw.Clear(); TxtActNewName.Clear();
                var _ = LoadUsersAsync();
            }
            var said = _pending.Select(p => p.Name + "\n" + (string.IsNullOrEmpty(p.StatusDetail) ? p.Status : p.StatusDetail)).ToList();
            var lead = "";
            if (_batchTab == "Share" && done > 0 && _pending.Any(p => (p.Id ?? "").StartsWith("share-") && p.Id != "share-setup" && p.Id != "share-down" && (p.Status ?? "").StartsWith("Applied")))
                lead = "On the other PC: Data Backup > Backup > Network..., pick " + Environment.MachineName + ", and sign in as " + Environment.MachineName + "\\" + Environment.UserName + " (or any other account of this PC).\n\n";
            ShowOverlay(fail > 0 ? "Finished - with a failure" : (cans > 0 ? "Finished - check the details" : "Finished"),
                        lead + summary + "\n\n" + string.Join("\n\n", said));
        }
    }
}
