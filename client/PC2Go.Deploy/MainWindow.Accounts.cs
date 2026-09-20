using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Data;
using System.Windows.Input;
using System.Windows.Media.Animation;
using PC2Go.Deploy.Models;
using PC2Go.Deploy.Services;

namespace PC2Go.Deploy
{
    /// <summary>
    /// The User Accounts tab. The list is read by the script's own functions through the reader
    /// (Get-UserProfiles, Get-LocalAccounts); clicking a row opens that account's dialog, and each
    /// verb becomes one queue entry for the elevated worker - the same entries the script writes,
    /// password fields DPAPI-protected before the worker exists. The worker re-checks every refusal
    /// (Test-AccountActionSafe) because the queue file is user-writable; the checks here are the
    /// ones that save a UAC prompt.
    /// </summary>
    public partial class MainWindow
    {
        private readonly ObservableCollection<AppItem> _acctItems = new ObservableCollection<AppItem>();
        private ListCollectionView _acctView;
        private List<ProfileRec> _acctProfiles = new List<ProfileRec>();
        private string _me = "";
        private bool _usersLoaded, _acctLoading, _userSelecting;
        // true once the accounts read has ANSWERED (or failed): the empty-state sentences wait for it
        private bool _acctReady;
        private AppItem _acctTarget;

        private void WireAccounts()
        {
            _acctView = (ListCollectionView)CollectionViewSource.GetDefaultView(_acctItems);
            _acctView.GroupDescriptions.Add(new PropertyGroupDescription("Category"));
            // the group names are chosen so "Accounts in use" sorts before "Built into Windows, or switched off"
            _acctView.SortDescriptions.Add(new SortDescription("Category", ListSortDirection.Ascending));
            _acctView.SortDescriptions.Add(new SortDescription("Name", ListSortDirection.Ascending));
            ListAccounts.ItemsSource = _acctView;
            BtnNewAccount.Click += (s, e) => OnNewAccountClick();
            BtnNewUserCancel.Click += (s, e) => NewUserOverlay.Visibility = Visibility.Collapsed;
            BtnNewUserOk.Click += (s, e) => OnNewUserOk();
            TxtNewUser.TextChanged += (s, e) => HintNewUser.Visibility = TxtNewUser.Text.Length > 0 ? Visibility.Collapsed : Visibility.Visible;
            TxtNewFull.TextChanged += (s, e) => HintNewFull.Visibility = TxtNewFull.Text.Length > 0 ? Visibility.Collapsed : Visibility.Visible;
            TxtNewPw.TextChanged += (s, e) => HintNewPw.Visibility = TxtNewPw.Text.Length > 0 ? Visibility.Collapsed : Visibility.Visible;
            TxtActPw.TextChanged += (s, e) => HintActPw.Visibility = TxtActPw.Text.Length > 0 ? Visibility.Collapsed : Visibility.Visible;
            TxtActNewName.TextChanged += (s, e) => HintActNewName.Visibility = TxtActNewName.Text.Length > 0 ? Visibility.Collapsed : Visibility.Visible;
            BtnAcctClose.Click += (s, e) => HideAcctDialog();
            BtnActAdmin.Click += (s, e) => OnActAdmin();
            BtnActStandard.Click += (s, e) => OnActStandard();
            BtnActPw.Click += (s, e) => OnActPw();
            BtnActToggle.Click += (s, e) => OnActToggle();
            BtnActDelete.Click += (s, e) => OnActDelete();
            BtnActLocal.Click += (s, e) => OnActLocal();
        }

        /// <summary>Accounts change under us constantly (one was just created, someone signed in), so the list is built on first visit, not at startup.</summary>
        private void OnAccountsTabShown()
        {
            if (_usersLoaded) return;
            _usersLoaded = true;
            var _ = LoadUsersAsync();
        }

        private async Task LoadUsersAsync()
        {
            if (_acctLoading) return;
            _acctLoading = true;
            TxtBusy.Text = "Reading the accounts on this PC...";
            BusyOverlay.Visibility = Visibility.Visible;
            Cursor = Cursors.Wait;
            try
            {
                var json = await _reader.RunAsync("accounts", null, null, CancellationToken.None, 180);
                var load = AccountList.Parse(json);
                _me = load.Me;
                _acctProfiles = load.Profiles;
                ListAccounts.ItemsSource = null;
                _acctItems.Clear();
                foreach (var a in load.Accounts)
                {
                    var prof = load.Profiles.FirstOrDefault(p => p.Sid == a.Sid || p.Name == a.Name);
                    var u = AccountList.Row(a, prof, load.Me);
                    // clicking a row IS the action - open that account's dialog
                    u.PropertyChanged += (s, e) =>
                    {
                        if (e.PropertyName != "IsSelected" || _userSelecting) return;
                        var it = (AppItem)s;
                        if (it.IsSelected) { SelectOnlyOneAccount(it); ShowAcctDialog(it); }
                    };
                    _acctItems.Add(u);
                }
                ListAccounts.ItemsSource = _acctView;
                _acctView.Refresh();
                OnUsersLoaded(load);   // the Data Backup tab's two lists come from the same read
                TxtAcctHint.Text = AccountList.Hint(load);
                EmptyAccounts.Text = _acctItems.Count == 0 ? "No local accounts could be listed on this PC." : "";
                EmptyAccounts.Visibility = _acctItems.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
                Log("Users: " + Format.Count(load.Profiles.Count, "profile", "profiles") + " on disk, " + Format.Count(_acctItems.Count, "local account", "local accounts") + ", " + Format.Count(load.Accounts.Count(a => a.IsAdmin), "Administrator", "Administrators") + ".");
            }
            catch (Exception ex)
            {
                Log("Users: the account list could not be read - " + ex.Message);
                TxtAcctHint.Text = "";
                EmptyAccounts.Text = "The accounts could not be listed.\n\n" + ex.Message;
                EmptyAccounts.Visibility = Visibility.Visible;
            }
            finally
            {
                BusyOverlay.Visibility = Visibility.Collapsed;
                Cursor = null;
                _acctLoading = false;
                _acctReady = true;
                SyncUserHint();
                UpdateUserEmptyStates();
                UpdateDash();
            }
        }

        private void SelectOnlyOneAccount(AppItem keep)
        {
            _userSelecting = true;
            try { foreach (var x in _acctItems) if (!ReferenceEquals(x, keep)) x.IsSelected = false; }
            finally { _userSelecting = false; }
        }

        private int EnabledAdmins() { return _acctItems.Count(x => x.RegKey == "admin" && x.IsSilent); }

        private static void FadeIn(FrameworkElement el)
        {
            el.Opacity = 0;
            el.Visibility = Visibility.Visible;
            el.BeginAnimation(OpacityProperty, new DoubleAnimation(0, 1, new Duration(TimeSpan.FromMilliseconds(180))));
        }

        // ------------------------------------------------------------------ the per-account dialog

        private void ShowAcctDialog(AppItem acct)
        {
            if (acct == null) return;
            _acctTarget = acct;
            TxtAcctInitial.Text = acct.IconText;
            TxtAcctName.Text = acct.Name;
            TxtAcctMeta.Text = acct.Publisher;
            var isAdmin = acct.RegKey == "admin";
            var enabled = acct.IsSilent;
            var isBuiltin = AccountList.IsBuiltin(acct.DetectPath, acct.Name);
            var isMe = acct.Name == _me;
            // only what applies to THIS account
            BtnActAdmin.Visibility = isAdmin ? Visibility.Collapsed : Visibility.Visible;
            BtnActStandard.Visibility = (isAdmin && !isBuiltin) ? Visibility.Visible : Visibility.Collapsed;
            BtnActToggle.Content = enabled ? "Disable account" : "Enable account";
            BtnActToggle.Visibility = (enabled && isMe) ? Visibility.Collapsed : Visibility.Visible;
            var msa = (acct.Publisher ?? "").IndexOf("Microsoft account", StringComparison.OrdinalIgnoreCase) >= 0;
            BtnActLocal.Visibility = msa ? Visibility.Visible : Visibility.Collapsed;
            BtnActDelete.Visibility = (isBuiltin || isMe) ? Visibility.Collapsed : Visibility.Visible;
            RowActNewName.Visibility = BtnActLocal.Visibility;
            // both boxes start empty, so a password typed for one account is never proposed for the next
            TxtActPw.Clear(); TxtActNewName.Clear();
            FadeIn(AcctOverlay);
        }

        /// <summary>The boxes are NOT cleared here: every action closes the dialog first and reads its box afterwards.</summary>
        private void HideAcctDialog()
        {
            AcctOverlay.Visibility = Visibility.Collapsed;
            _userSelecting = true;
            try { foreach (var x in _acctItems) x.IsSelected = false; } finally { _userSelecting = false; }
            _acctTarget = null;
        }

        /// <summary>Get-AccountTarget: the row that opened the dialog. Closing the dialog first stops two modals stacking.</summary>
        private AppItem GetAccountTarget(string verb)
        {
            var a = _acctTarget;
            HideAcctDialog();
            if (TestBatchBusy()) return null;
            if (a == null) { ShowOverlay("No account selected", "Click the account you want to " + verb + "."); return null; }
            return a;
        }

        // ------------------------------------------------------------------ Add Account

        private void OnNewAccountClick()
        {
            if (TestBatchBusy()) return;
            TxtNewUser.Clear(); TxtNewFull.Clear(); TxtNewPw.Clear();
            ChkNewAdmin.IsChecked = true;
            FadeIn(NewUserOverlay);
            TxtNewUser.Focus();
        }

        private void OnNewUserOk()
        {
            if (TestBatchBusy()) return;
            var name = (TxtNewUser.Text ?? "").Trim();
            if (name.Length == 0) { ShowOverlay("No name", "Type the account name to create."); return; }
            if (!AccountList.IsValidName(name)) { ShowOverlay("Invalid account name", AccountList.InvalidNameText); return; }
            // the whole list, disabled accounts included - a name matching a DISABLED account used to
            // sail through and fail in the worker with no reason, for a name plainly visible above
            var clash = _acctItems.FirstOrDefault(x => string.Equals(x.Name, name, StringComparison.OrdinalIgnoreCase));
            if (clash != null)
            {
                ShowOverlay("Account exists", "There is already a local account called \"" + name + "\" on this machine" +
                    (clash.IsSilent ? "." : ", and it is currently DISABLED. Enable it from the Accounts tab rather than creating a second one."));
                return;
            }
            var full = (TxtNewFull.Text ?? "").Trim();
            if (full.Length == 0) full = name;
            var pw = TxtNewPw.Text ?? "";
            var asAdmin = ChkNewAdmin.IsChecked == true;
            NewUserOverlay.Visibility = Visibility.Collapsed;
            var msg = "Sign-in name:   " + name + "\n" +
                      "Display name:   " + full + (full == name ? "   (same as the sign-in name)" : "") + "\n" +
                      "Profile folder: C:\\Users\\" + name + "\n" +
                      "Password:       " + (pw.Length > 0 ? pw : "none") + "\n\n" +
                      "It will be:\n" +
                      "  - " + (asAdmin ? "a member of Administrators, NOT a standard user" : "a STANDARD user") + "\n" +
                      "  - set never to expire\n" +
                      "  - given its profile folder straight away, so you can copy data in without signing into it first\n\n" +
                      (pw.Length > 0 ? "The password is shown here so you can read it back to the client."
                                     : "With no password, anyone at the keyboard can sign in. Type one in the Password box, or use Set Password afterwards.");
            ShowConfirm("Create this account?", msg, "Continue", () => StartUserBatch("newuser",
                new Dictionary<string, object> { { "username", name }, { "fullname", full }, { "password", pw }, { "admin", asAdmin } }));
        }

        // ------------------------------------------------------------------ the verbs

        private void OnActAdmin()
        {
            var a = GetAccountTarget("promote");
            if (a == null) return;
            if (a.RegKey == "admin") { ShowOverlay("Already an Administrator", "\"" + a.Name + "\" is already in the Administrators group."); return; }
            ShowConfirm("Promote to Administrator?",
                "\"" + a.Name + "\" becomes a full Administrator: it can install software, change any setting and read every user's files.\n\n" +
                "Only do this for a technician or owner account.",
                "Continue", () => StartUserBatch("setadmin", new Dictionary<string, object> { { "username", a.UnArgs ?? "" }, { "admin", true } }));
        }

        private void OnActStandard()
        {
            var a = GetAccountTarget("demote");
            if (a == null) return;
            if (a.RegKey != "admin") { ShowOverlay("Already standard", "\"" + a.Name + "\" is not an Administrator."); return; }
            // losing the last admin means nobody can ever elevate on this machine again
            var admins = EnabledAdmins();
            if (admins <= 1)
            {
                ShowOverlay("Refused - last Administrator",
                    "\"" + a.Name + "\" is the only enabled Administrator on this machine.\n\n" +
                    "Demoting it would leave nobody able to elevate, install software or undo the change. Create another admin first.");
                return;
            }
            ShowConfirm("Demote to Standard user?",
                "\"" + a.Name + "\" loses Administrator rights and can no longer elevate.\n\n" + (admins - 1 == 1 ? "1 other Administrator remains." : Format.Count(admins - 1, "other Administrator", "other Administrators") + " remain."),
                "Continue", () => StartUserBatch("setadmin", new Dictionary<string, object> { { "username", a.UnArgs ?? "" }, { "admin", false } }));
        }

        private void OnActPw()
        {
            var a = GetAccountTarget("set a password for");
            if (a == null) return;
            // this dialog's own box - the Add Account dialog's is a different popup and is not on screen
            var pw = TxtActPw.Text ?? "";
            var what = pw.Length > 0 ? "the password typed in the Password box above" : "NO password at all";
            ShowConfirm("Set this password?",
                "\"" + a.Name + "\" will be given " + what + ".\n\n" +
                (pw.Length > 0 ? "Password: " + pw + "\n\nIt is shown so you can read it back to the client."
                               : "A password-free account means anyone at the keyboard can sign in. Type one in the Password box first if that is not what you want."),
                "Continue", () => StartUserBatch("setpassword", new Dictionary<string, object> { { "username", a.UnArgs ?? "" }, { "password", pw } }));
        }

        private void OnActToggle()
        {
            var a = GetAccountTarget("enable or disable");
            if (a == null) return;
            var enable = !a.IsSilent;      // IsSilent carries "currently enabled"
            if (!enable)
            {
                if (a.Name == _me)
                {
                    ShowOverlay("Refused - that is you", "\"" + a.Name + "\" is the account running this tool. Disabling it would lock you out of the session.");
                    return;
                }
                if (a.RegKey == "admin" && EnabledAdmins() <= 1)
                {
                    ShowOverlay("Refused - last Administrator", "\"" + a.Name + "\" is the only enabled Administrator. Disabling it would leave nobody able to elevate.");
                    return;
                }
            }
            var verb = enable ? "Enable" : "Disable";
            // turning the built-in Administrator on is a hardening decision, not routine
            if (enable && AccountList.IsBuiltin(a.DetectPath, a.Name))
            {
                ShowConfirm("Enable a built-in Windows account?",
                    "\"" + a.Name + "\" is a built-in account that Windows ships DISABLED on purpose - it is a well-known target, and on many machines it has no password.\n\n" +
                    "Enable it only for recovery, and set a password immediately afterwards.\n\n" +
                    "You can switch it back off from here at any time.",
                    "Continue", () => StartUserBatch("toggleacct", new Dictionary<string, object> { { "username", a.UnArgs ?? "" }, { "enable", true } }));
                return;
            }
            ShowConfirm(verb + " this account?",
                enable ? "\"" + a.Name + "\" will be able to sign in again. Its profile and files are unchanged."
                       : "\"" + a.Name + "\" will no longer be able to sign in.\n\nNothing is deleted - the profile and all its files stay on disk, and you can enable it again from here. This is the safe alternative to deleting an account.",
                "Continue", () => StartUserBatch("toggleacct", new Dictionary<string, object> { { "username", a.UnArgs ?? "" }, { "enable", enable } }));
        }

        private void OnActDelete()
        {
            var a = GetAccountTarget("delete");
            if (a == null) return;
            if (a.Name == _me) { ShowOverlay("Refused - that is you", "\"" + a.Name + "\" is the account running this tool. It cannot delete itself."); return; }
            if (AccountList.IsBuiltin(a.DetectPath, a.Name))
            {
                ShowOverlay("Refused - built-in account", "\"" + a.Name + "\" is a built-in Windows account. Removing it is not supported and breaks servicing.");
                return;
            }
            if (a.RegKey == "admin" && EnabledAdmins() <= 1)
            {
                ShowOverlay("Refused - last Administrator", "\"" + a.Name + "\" is the only enabled Administrator on this machine. Deleting it would leave nobody able to elevate.");
                return;
            }
            // the profile is KEPT: deleting an account and its data in one click is how a migration that missed something becomes a disaster
            ShowConfirm("Delete this account?",
                "The account \"" + a.Name + "\" will be removed from Windows.\n\n" +
                "Its profile folder is NOT deleted - " + a.Publisher + "\n" +
                "The files stay on disk, so anything the migration missed is still recoverable. Remove the folder yourself once the new profile is confirmed working.\n\n" +
                "Consider Disable instead: it blocks sign-in and is completely reversible.",
                "Continue", () => StartUserBatch("deleteaccount", new Dictionary<string, object> { { "username", a.UnArgs ?? "" } }));
        }

        /// <summary>
        /// Windows exposes no API to convert a Microsoft sign-in to a local one in place, so this does
        /// not "convert" anything: it stands up a real local admin, moves the data into it, and
        /// switches the old account off - the outcome that IS automatable.
        /// </summary>
        private void OnActLocal()
        {
            var a = GetAccountTarget("replace with a local account");
            if (a == null) return;
            if ((a.Publisher ?? "").IndexOf("Microsoft account", StringComparison.OrdinalIgnoreCase) < 0)
            {
                ShowConfirm("That is already a local account",
                    "\"" + a.Name + "\" is not signed in with a Microsoft account, so there is nothing to replace.\n\n" +
                    "Continue anyway only if you want to build a fresh local admin beside it and move the data across.",
                    "Continue", () => { var _ = ReplaceWithLocalAsync(a); });
                return;
            }
            var __ = ReplaceWithLocalAsync(a);
        }

        private async Task ReplaceWithLocalAsync(AppItem acct)
        {
            // this dialog's own boxes - the Add Account dialog's are not on screen here
            var name = (TxtActNewName.Text ?? "").Trim();
            if (name.Length == 0)
            {
                ShowOverlay("Name the new account first",
                    "Type the new local account's sign-in name in the box above, then press this again.\n\n" +
                    "It becomes the replacement for \"" + acct.Name + "\" - a real Administrator with no Microsoft account attached.");
                return;
            }
            if (!AccountList.IsValidName(name)) { ShowOverlay("Invalid account name", AccountList.InvalidNameText); return; }
            if (_acctItems.Any(x => string.Equals(x.Name, name, StringComparison.OrdinalIgnoreCase)))
            {
                ShowOverlay("Account exists", "There is already an account called \"" + name + "\". Pick a different name.");
                return;
            }
            var prof = _acctProfiles.FirstOrDefault(p => p.Sid == acct.DetectPath || p.Name == acct.Name);
            if (prof == null)
            {
                ShowOverlay("No profile to copy", "\"" + acct.Name + "\" has no profile folder on this machine yet, so there is nothing to move. Create the account normally instead.");
                return;
            }
            // only the safe defaults, and only those that actually exist - the script's own table, through the reader
            string[] items;
            try
            {
                var json = await _reader.RunAsync("migrateitems", Json.Serialize(new Dictionary<string, object> { { "path", prof.Path } }), null, CancellationToken.None, 120);
                var root = Json.ParseObject(json);
                items = root == null ? new string[0] : Json.Strings(root, "items");
            }
            catch (Exception ex) { ShowOverlay("Could not look at the profile", ex.Message); return; }

            var isSelf = acct.Name == _me;
            var pw = TxtActPw.Text ?? "";
            var steps = new List<UserStep>
            {
                new UserStep("newuser", "Create local admin \"" + name + "\"",
                    new Dictionary<string, object> { { "username", name }, { "fullname", name }, { "password", pw } }),
                new UserStep("migrate", "Copy " + Format.Count(items.Length, "folder", "folders") + " from \"" + acct.Name + "\"",
                    new Dictionary<string, object> { { "src", prof.Path }, { "dstUser", name }, { "dstPath", "" }, { "items", items } }),
            };
            // disabling the account you are signed into would end the session mid-copy - leave it running and say what to do
            if (!isSelf)
                steps.Add(new UserStep("toggleacct", "Disable \"" + acct.Name + "\"",
                    new Dictionary<string, object> { { "username", acct.Name }, { "enable", false } }));

            var msg = "Windows cannot convert a Microsoft sign-in to a local one from a script - there is no API for it, " +
                      "and the only supported route is the Settings wizard, which asks for the account password.\n\n" +
                      "What this does instead, all under one UAC prompt:\n\n" +
                      "  1. Create \"" + name + "\" as a local Administrator" + (pw.Length > 0 ? " with the password above" : ", no password") + "\n" +
                      "  2. Copy " + Format.Count(items.Length, "data folder", "data folders") + " from \"" + acct.Name + "\" into it - nothing is moved or deleted\n";
            if (isSelf)
                msg += "  3. (skipped) \"" + acct.Name + "\" is the account you are signed into, so it is left enabled\n\n" +
                       "Sign into \"" + name + "\" afterwards and disable the old account from this tab.";
            else
                msg += "  3. Disable \"" + acct.Name + "\" so it can no longer sign in - reversible, and its files stay on disk\n\n" +
                       "The Microsoft account itself is untouched; it is only switched off on this PC.";
            msg += "\n\nPrefer a true in-place conversion, keeping the same profile and SID? Cancel and use " +
                   "Settings > Accounts > Your info > Sign in with a local account instead.";
            ShowConfirm("Replace with a local admin?", msg, "Continue", () => StartUserChain(steps));
        }

        private sealed class UserStep
        {
            public readonly string Action, Label;
            public readonly Dictionary<string, object> Data;
            public UserStep(string action, string label, Dictionary<string, object> data) { Action = action; Label = label; Data = data; }
        }

        // ------------------------------------------------------------------ the batch

        private Dictionary<string, object> UserEntry(string id, string action, bool chain, Dictionary<string, object> data)
        {
            var e = new Dictionary<string, object> { { "id", id }, { "action", action } };
            if (chain) e["chain"] = true;
            // techUser is the signed-in account, which the worker cannot see for itself - see Test-AccountActionSafe
            e["techUser"] = _me;
            foreach (var kv in data) e[kv.Key] = kv.Value;
            return AccountList.Protect(e);
        }

        private void BeginUserBatch(List<AppItem> rows, string tab)
        {
            _pending = rows;
            // 'Migrate' when the job IS a migration, or Update-Dash decides this batch belongs to the Users panel
            _batchTab = tab;
            _runStarted = DateTime.Now;
            _dlIndex = 0; _lastLogKey.Clear();
            _hadFailures = false; _cancelRequested = false; _awaitingScan = false;
            _deepClean = false; _forceMode = false;
            _worker.ResetForBatch();
            ShowBatchStrip();
        }

        /// <summary>Start-UserBatch: one row, one entry, protected BEFORE the worker is launched - a throw after Start-Worker left an elevated process polling a queue that never got its end marker.</summary>
        private void StartUserBatch(string action, Dictionary<string, object> data)
        {
            var row = new AppItem { Id = "user-" + action, Name = AccountList.JobName(action, data), Category = "Users", IconBg = "#FF2563EB", IconData = Catalog.IconMap["default"][0], RowOpacity = 1.0 };
            Dictionary<string, object> entry;
            try { entry = UserEntry(row.Id, action, false, data); }
            catch (Exception ex) { ShowOverlay("Could not protect the password", "The password could not be encrypted for the elevated worker, so nothing was started.\n\n" + ex.Message); return; }
            SetStatus(row, "Queued", "neutral");
            SetRing(row, "busy");
            BeginUserBatch(new List<AppItem> { row }, action == "migrate" ? "Migrate" : "Users");
            if (!_worker.Start()) { AbortBatch("the administrator prompt was declined, so nothing was run", "warn"); return; }
            _worker.Enqueue(entry);
            _worker.Complete();
            _phase = "Install";
            BtnNewAccount.IsEnabled = false;
            BtnMigrate.IsEnabled = false;
            BtnInstall.IsEnabled = false;
            TxtNow.Text = row.Name;
            DotNow.Fill = Brush("#FF4C8DFF");
            TxtStatus.Text = AccountList.JobStatus(action, data);
            Log(row.Name + " - started.");
            UpdateDash();
        }

        /// <summary>Start-UserChain: ordered and dependent steps (`chain`) - if one fails, the ones after it must not run.</summary>
        private void StartUserChain(List<UserStep> steps)
        {
            var rows = new List<AppItem>();
            var entries = new List<Dictionary<string, object>>();
            try
            {
                for (int i = 0; i < steps.Count; i++)
                {
                    var row = new AppItem { Id = "chain" + (i + 1), Name = steps[i].Label, Category = "Users", IconBg = "#FF2563EB", IconData = Catalog.IconMap["default"][0], RowOpacity = 1.0 };
                    rows.Add(row);
                    entries.Add(UserEntry(row.Id, steps[i].Action, true, steps[i].Data));
                }
            }
            catch (Exception ex) { ShowOverlay("Could not protect the password", "The password could not be encrypted for the elevated worker, so nothing was started.\n\n" + ex.Message); return; }
            foreach (var r in rows) { SetStatus(r, "Queued", "neutral"); SetRing(r, "queued"); }
            BeginUserBatch(rows, "Users");
            if (!_worker.Start()) { AbortBatch("the administrator prompt was declined, so nothing was run", "warn"); return; }
            foreach (var e in entries) _worker.Enqueue(e);
            _worker.Complete();
            _phase = "Install";
            BtnNewAccount.IsEnabled = false;
            BtnMigrate.IsEnabled = false;
            BtnInstall.IsEnabled = false;
            TxtNow.Text = rows[0].Name;
            DotNow.Fill = Brush("#FF4C8DFF");
            TxtStatus.Text = "Running " + Format.Count(steps.Count, "step", "steps") + "...";
            Log("User chain started: " + Format.Count(steps.Count, "step", "steps") + " - " + string.Join(" -> ", steps.Select(s => s.Action)) + ".");
            UpdateDash();
        }

        /// <summary>
        /// Finish-Batch's Users part: the boxes are cleared so a set password does not survive in a
        /// dialog, the closing sheet says per row what the worker wrote (a one-row batch's "1
        /// completed, 0 failed" is the least useful sentence there is), and the list is re-read.
        /// </summary>
        private void OnBatchEndedUsers(string summary, int fail, int cans)
        {
            BtnNewAccount.IsEnabled = true;
            if (_batchTab != "Users") return;
            TxtNewUser.Clear(); TxtNewFull.Clear(); TxtNewPw.Clear();
            TxtActPw.Clear(); TxtActNewName.Clear();
            var said = _pending.Select(p => p.Name + "\n" + (string.IsNullOrEmpty(p.StatusDetail) ? p.Status : p.StatusDetail)).ToList();
            ShowOverlay(fail > 0 ? "Finished - with a failure" : (cans > 0 ? "Finished - check the details" : "Finished"),
                        summary + "\n\n" + string.Join("\n\n", said));
            var _ = LoadUsersAsync();
        }
    }
}
