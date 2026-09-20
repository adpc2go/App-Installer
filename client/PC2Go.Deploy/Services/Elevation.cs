using System;
using System.DirectoryServices;
using System.DirectoryServices.AccountManagement;
using System.Security.Principal;

namespace PC2Go.Deploy.Services
{
    public static class Elevation
    {
        /// <summary>
        /// Ask the GROUP, not the token. On a filtered (unelevated) token the Administrators SID may
        /// be deny-only or absent altogether - measured absent on a machine whose user is definitely
        /// an administrator. The token describes what this process may do right now, which is a
        /// different question from whether the account is an administrator.
        /// </summary>
        public static bool IsAdminMember()
        {
            string mySid = null, myName = null;
            try
            {
                using (var id = WindowsIdentity.GetCurrent()) { mySid = id.User.Value; myName = id.Name; }
            }
            catch { return false; }

            try
            {
                using (var ctx = new PrincipalContext(ContextType.Machine))
                using (var grp = GroupPrincipal.FindByIdentity(ctx, IdentityType.Sid, "S-1-5-32-544"))
                {
                    if (grp != null)
                    {
                        foreach (var m in grp.GetMembers(false))
                        {
                            try { if (m.Sid != null && m.Sid.Value == mySid) return true; } catch { }
                        }
                        return false;
                    }
                }
            }
            catch { }

            // the ADSI view, older than any machine this will run on
            try
            {
                var shortName = (myName ?? "").Split('\\');
                var me = shortName[shortName.Length - 1];
                using (var grp = new DirectoryEntry("WinNT://./Administrators,group"))
                {
                    foreach (var m in (System.Collections.IEnumerable)grp.Invoke("Members"))
                    {
                        using (var de = new DirectoryEntry(m))
                        {
                            if (string.Equals(de.Name, me, StringComparison.OrdinalIgnoreCase)) return true;
                        }
                    }
                }
            }
            catch { }
            return false;
        }
    }
}
