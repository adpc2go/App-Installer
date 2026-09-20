using System;
using System.Collections.Generic;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using PC2Go.Deploy.Models;

namespace PC2Go.Deploy.Services
{
    /// <summary>One local account, as Get-LocalAccounts reports it through the reader.</summary>
    public sealed class AccountRec
    {
        public string Sid = "", Name = "", FullName = "", Kind = "", Purpose = "";
        public bool Enabled, IsAdmin, IsBuiltin;
    }

    /// <summary>One profile folder on disk, as Get-UserProfiles reports it.</summary>
    public sealed class ProfileRec
    {
        public string Sid = "", Name = "", Path = "";
    }

    public sealed class AccountLoad
    {
        public string Me = "";
        public List<AccountRec> Accounts = new List<AccountRec>();
        public List<ProfileRec> Profiles = new List<ProfileRec>();
    }

    /// <summary>
    /// Load-Users' row projection, the account-name rule, the built-in test and Protect-QueueEntry -
    /// the pieces of the User Accounts tab that are not reads and not the window.
    /// </summary>
    public static class AccountList
    {
        public const string CatInUse = "Accounts in use";
        public const string CatWindows = "Built into Windows, or switched off";
        public const string SecretPrefix = "DPAPI:";
        public static readonly string[] SecretFields = { "password", "alPassword", "netPassword" };
        public static readonly string[] BuiltinNames = { "Administrator", "Guest", "DefaultAccount", "WDAGUtilityAccount" };
        private static readonly Regex BuiltinRid = new Regex("-(500|501|503|504)$", RegexOptions.Compiled);
        private static readonly Regex BadNameChars = new Regex(@"[\\/""\[\]:;|=,+*?<>@]", RegexOptions.Compiled);
        private static readonly Regex OnlyDotsOrSpaces = new Regex("^[. ]+$", RegexOptions.Compiled);

        public static AccountLoad Parse(string json)
        {
            var load = new AccountLoad();
            var root = Json.ParseObject(json);
            if (root == null) return load;
            load.Me = Json.Str(root, "me");
            foreach (var o in Json.Arr(root, "profiles"))
            {
                var d = o as Dictionary<string, object>;
                if (d == null) continue;
                load.Profiles.Add(new ProfileRec { Sid = Json.Str(d, "Sid"), Name = Json.Str(d, "Name"), Path = Json.Str(d, "Path") });
            }
            foreach (var o in Json.Arr(root, "accounts"))
            {
                var d = o as Dictionary<string, object>;
                if (d == null) continue;
                load.Accounts.Add(new AccountRec
                {
                    Sid = Json.Str(d, "Sid"), Name = Json.Str(d, "Name"), FullName = Json.Str(d, "FullName"), Kind = Json.Str(d, "Kind"),
                    Purpose = Json.Str(d, "Purpose"), Enabled = Json.Bool(d, "Enabled"), IsAdmin = Json.Bool(d, "IsAdmin"), IsBuiltin = Json.Bool(d, "IsBuiltin"),
                });
            }
            return load;
        }

        /// <summary>Load-Users' account rows, field for field: UnArgs is the name every entry ships, DetectPath the SID, IsSilent "enabled", RegKey admin|standard, Size the badge.</summary>
        public static AppItem Row(AccountRec a, ProfileRec prof, string me)
        {
            var bits = new List<string> { a.IsAdmin ? "Administrator" : "Standard user" };
            if (a.Purpose.Length > 0) bits.Add(a.Purpose);
            else if (a.Kind.Length > 0) bits.Add(a.Kind);
            if (a.FullName.Length > 0 && a.FullName != a.Name) bits.Add("shown as \"" + a.FullName + "\"");
            if (prof != null) bits.Add(prof.Path);
            else if (a.Purpose.Length > 0) bits.Add("no profile folder");
            else bits.Add("no profile folder yet");
            var u = new AppItem
            {
                Id = "acct-" + a.Name, Name = a.Name, Publisher = string.Join("   -   ", bits), Version = "",
                Size = !a.Enabled ? "DISABLED" : (a.Name == me ? "SIGNED IN" : (a.IsAdmin ? "ADMIN" : "STANDARD")),
                IconText = a.Name.Length > 0 ? a.Name.Substring(0, 1).ToUpperInvariant() : "?",
                UnArgs = a.Name, DetectPath = a.Sid, IsSilent = a.Enabled, RegKey = a.IsAdmin ? "admin" : "standard",
                IconBg = !a.Enabled ? "#FF4A4A52" : (a.IsAdmin ? "#FF2563EB" : "#FF64748B"),
                IconData = Catalog.IconMap["default"][0], RowOpacity = 1.0,
                Category = (a.Purpose.Length > 0 || !a.Enabled) ? CatWindows : CatInUse,
            };
            return u;
        }

        /// <summary>The header line under "Accounts on this PC".</summary>
        public static string Hint(AccountLoad load)
        {
            var adminAll = load.Accounts.Count(a => a.IsAdmin);
            var adminOn = load.Accounts.Count(a => a.IsAdmin && a.Enabled);
            var adminTxt = adminAll != adminOn ? Format.Count(adminOn, "usable administrator", "usable administrators") + " (" + (adminAll - adminOn) + " disabled)" : Format.Count(adminOn, "administrator", "administrators");
            return Format.Count(load.Accounts.Count, "account", "accounts") + ", " + adminTxt;
        }

        /// <summary>The well-known RIDs and names Windows ships with - never deleted or demoted, enabled only after a warning.</summary>
        public static bool IsBuiltin(string sid, string name)
        {
            return BuiltinRid.IsMatch(sid ?? "") || BuiltinNames.Any(n => string.Equals(n, name ?? "", StringComparison.OrdinalIgnoreCase));
        }

        /// <summary>Windows rejects these outright; a name that is only dots or spaces, or ends in a dot, is refused by SAM and is a folder Windows cannot create.</summary>
        public static bool IsValidName(string name)
        {
            name = name ?? "";
            return name.Length > 0 && !BadNameChars.IsMatch(name) && name.Length <= 20 && !OnlyDotsOrSpaces.IsMatch(name) && !name.EndsWith(".", StringComparison.Ordinal);
        }

        public const string InvalidNameText = "Windows account names cannot contain  \\ / \" [ ] : ; | = , + * ? < > @  " +
                                              "must be 20 characters or fewer, and cannot be only dots or end in one.";

        /// <summary>Protect-Secret: DPAPI, LocalMachine scope, no entropy - the elevated worker on this machine is the only reader. Throws rather than degrading to plaintext.</summary>
        public static string ProtectSecret(string value)
        {
            if (string.IsNullOrEmpty(value)) return "";
            var bytes = ProtectedData.Protect(Encoding.UTF8.GetBytes(value), null, DataProtectionScope.LocalMachine);
            return SecretPrefix + Convert.ToBase64String(bytes);
        }

        /// <summary>Protect-QueueEntry: a copy of the entry with every non-empty secret field protected.</summary>
        public static Dictionary<string, object> Protect(Dictionary<string, object> entry)
        {
            var copy = new Dictionary<string, object>(entry);
            foreach (var f in SecretFields)
            {
                if (!copy.ContainsKey(f)) continue;
                var v = copy[f] as string;
                if (!string.IsNullOrEmpty(v)) copy[f] = ProtectSecret(v);
            }
            return copy;
        }

        /// <summary>Start-UserBatch's row name for a job.</summary>
        public static string JobName(string action, Dictionary<string, object> data)
        {
            Func<string, string> s = k => data.ContainsKey(k) ? (data[k] as string ?? "") : "";
            Func<string, bool> b = k => data.ContainsKey(k) && data[k] is bool && (bool)data[k];
            switch (action)
            {
                case "newuser": return "Create account \"" + s("username") + "\"";
                case "migrate":
                {
                    // named for the job: a drive/USB backup has no destination ACCOUNT
                    var paths = data.ContainsKey("paths") ? data["paths"] as string[] : null;
                    if (s("srcKind") == "paths") return "Back up " + Format.Count((paths != null ? paths.Length : 0), "folder or drive", "folders and drives") + " to " + s("dstPath");
                    if (s("dstKind") == "paths") return s("restoreTo") == "orig" ? "Restore to where it came from" : "Restore backup into " + s("restoreTo");
                    if (s("srcKind") == "folder") return "Restore backup into \"" + s("dstUser") + "\"";
                    if (s("dstKind") == "folder") return "Back up data to " + s("dstPath");
                    return "Copy profile data to \"" + s("dstUser") + "\"";
                }
                case "setadmin": return b("admin") ? "Promote \"" + s("username") + "\" to Administrator" : "Demote \"" + s("username") + "\" to Standard";
                case "setpassword": return "Set password for \"" + s("username") + "\"";
                case "toggleacct": return b("enable") ? "Enable \"" + s("username") + "\"" : "Disable \"" + s("username") + "\"";
                case "deleteaccount": return "Delete account \"" + s("username") + "\"";
                default: return action;
            }
        }

        /// <summary>Start-UserBatch's status line while the job runs - one per job, not one for all.</summary>
        public static string JobStatus(string action, Dictionary<string, object> data)
        {
            Func<string, bool> b = k => data.ContainsKey(k) && data[k] is bool && (bool)data[k];
            Func<string, string> s = k => data.ContainsKey(k) ? (data[k] as string ?? "") : "";
            switch (action)
            {
                case "newuser": return "Creating the account...";
                case "migrate": return s("srcKind") == "folder" ? "Restoring the backup..." : (s("dstKind") == "folder" ? "Backing up profile data..." : "Copying profile data...");
                case "setadmin": return b("admin") ? "Adding to Administrators..." : "Removing from Administrators...";
                case "setpassword": return "Setting the password...";
                case "toggleacct": return b("enable") ? "Enabling the account..." : "Disabling the account...";
                case "deleteaccount": return "Deleting the account...";
                default: return "Working...";
            }
        }
    }
}
