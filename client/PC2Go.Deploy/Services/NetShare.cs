using System;
using System.Runtime.InteropServices;
using System.Text;

namespace PC2Go.Deploy.Services
{
    public sealed class ShareConn
    {
        public bool Ok, Prompted;
        public string Why = "", User = "", Password = "";
    }

    /// <summary>
    /// Reaching a share from the GUI: the same three rules the worker has. WNetAddConnection2,
    /// not `net use` - the API takes the password as an argument, so it never becomes a command
    /// line anything else can read. The sign-in prompt is Windows' own
    /// (CredUIPromptForWindowsCredentials), raised only after the machine has been reached and
    /// has actually refused - the box appearing is itself the proof that the PC was found.
    /// </summary>
    public static class NetShare
    {
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct NETRESOURCE
        {
            public int dwScope; public int dwType; public int dwDisplayType; public int dwUsage;
            public string lpLocalName; public string lpRemoteName; public string lpComment; public string lpProvider;
        }
        [DllImport("mpr.dll", CharSet = CharSet.Unicode)]
        private static extern int WNetAddConnection2(ref NETRESOURCE r, string password, string username, int flags);
        [DllImport("mpr.dll", CharSet = CharSet.Unicode)]
        private static extern int WNetCancelConnection2(string name, int flags, bool force);

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct CREDUI_INFO
        {
            public int cbSize; public IntPtr hwndParent;
            public string pszMessageText; public string pszCaptionText; public IntPtr hbmBanner;
        }
        [DllImport("credui.dll", CharSet = CharSet.Unicode)]
        private static extern int CredUIPromptForWindowsCredentials(ref CREDUI_INFO pUiInfo, int dwAuthError, ref uint pulAuthPackage,
            IntPtr pvInAuthBuffer, uint ulInAuthBufferSize, out IntPtr ppvOutAuthBuffer, out uint pulOutAuthBufferSize, ref bool pfSave, int dwFlags);
        [DllImport("credui.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool CredUnPackAuthenticationBuffer(int dwFlags, IntPtr pAuthBuffer, uint cbAuthBuffer,
            StringBuilder pszUserName, ref int pcchMaxUserName, StringBuilder pszDomainName, ref int pcchMaxDomainName,
            StringBuilder pszPassword, ref int pcchMaxPassword);
        [DllImport("ole32.dll")]
        private static extern void CoTaskMemFree(IntPtr ptr);

        /// <summary>\\server\share out of \\server\share\some\folder - a connection is made to the SHARE, never to a folder inside it.</summary>
        public static string ShareRoot(string path)
        {
            if (string.IsNullOrEmpty(path)) return "";
            var p = path.Trim();
            if (!p.StartsWith(@"\\", StringComparison.Ordinal)) return "";
            var parts = p.TrimStart('\\').Split(new[] { '\\' }, StringSplitOptions.RemoveEmptyEntries);
            if (parts.Length < 2) return "";
            return @"\\" + parts[0] + @"\" + parts[1];
        }

        /// <summary>The machine part of \\server\share.</summary>
        public static string Machine(string root)
        {
            var m = (root ?? "").Trim('\\');
            var cut = m.IndexOf('\\');
            return cut > 0 ? m.Substring(0, cut) : m;
        }

        /// <summary>Connect-Share: '' on success, otherwise why not; rc carries the Win32 code so a caller can tell "it refused you" from "it is not there".</summary>
        public static string Connect(string path, string user, string password, out int rc)
        {
            rc = -1;
            var root = ShareRoot(path);
            if (root.Length == 0) { rc = 0; return ""; }   // not a share at all: nothing to connect, and that is a success
            var nr = new NETRESOURCE { dwType = 1, lpRemoteName = root };   // RESOURCETYPE_DISK
            // NULL, never "": a NULL user and password mean "the identity this process runs as",
            // while an EMPTY password means "there is no password"
            var u = string.IsNullOrEmpty(user) ? null : user;
            var p = (u == null || string.IsNullOrEmpty(password)) ? null : password;
            try { rc = WNetAddConnection2(ref nr, p, u, 0); }
            catch (Exception ex) { return "could not reach " + root + " - " + ex.Message; }
            if (rc == 0) return "";
            if (rc == 1219)
                return root + " is already connected as a different user. Windows allows one identity per server at a time, so the existing connection has to be dropped before a different sign-in can be offered.";
            if (rc == 53 || rc == 55 || rc == 64 || rc == 67 || rc == 1231 || rc == 1232)
                return root + " could not be reached - check that PC is on, awake, and on this network";
            // mpr returns 5 BOTH for "you may not use this share" and "there is no such share"
            if (rc == 5) return root + " refused the connection. Either that folder is not shared, or the sign-in given is not allowed to use it.";
            if (rc == 1326) return "the username or password for " + root + " was not accepted";
            return "could not connect to " + root + " (error " + rc + ")";
        }

        public static void Disconnect(string path)
        {
            var root = ShareRoot(path);
            if (root.Length == 0) return;
            try { WNetCancelConnection2(root, 0, false); } catch { }
        }

        /// <summary>A bare username means an account ON THE OTHER PC; anything qualified (a backslash, an @) is left alone.</summary>
        public static string ResolveShareUser(string user, string machine)
        {
            var u = (user ?? "").Trim();
            if (u.Length == 0) return "";
            if (u.Contains("\\") || u.Contains("@")) return u;
            if (string.IsNullOrEmpty(machine)) return u;
            return machine + "\\" + u;
        }

        /// <summary>Request-ShareCredential: Windows' own prompt, generic (never written to Credential Manager), parented to the window; the buffer is zeroed before it is freed.</summary>
        public static bool PromptCredential(IntPtr hwnd, string target, int authError, out string user, out string password)
        {
            user = ""; password = "";
            var machine = Machine(target);
            var info = new CREDUI_INFO
            {
                cbSize = Marshal.SizeOf(typeof(CREDUI_INFO)), hwndParent = hwnd,
                pszCaptionText = "Sign in to " + machine,
                pszMessageText = machine + " answered, but it will not show what it shares without a sign-in.\n\nUse an account that exists ON THAT PC.",
            };
            uint pkg = 0; IntPtr outBuf = IntPtr.Zero; uint outSize = 0; bool save = false; int rc;
            try { rc = CredUIPromptForWindowsCredentials(ref info, authError, ref pkg, IntPtr.Zero, 0, out outBuf, out outSize, ref save, 1); }
            catch { return false; }
            if (rc != 0) return false;   // 1223 = ERROR_CANCELLED
            try
            {
                int uLen = 513, dLen = 513, pLen = 513;
                var u = new StringBuilder(uLen); var d = new StringBuilder(dLen); var p = new StringBuilder(pLen);
                if (CredUnPackAuthenticationBuffer(0, outBuf, outSize, u, ref uLen, d, ref dLen, p, ref pLen))
                {
                    user = u.ToString(); password = p.ToString();
                    return true;
                }
                return false;
            }
            finally
            {
                if (outBuf != IntPtr.Zero)
                {
                    try { for (int i = 0; i < (int)outSize; i++) Marshal.WriteByte(outBuf, i, 0); } catch { }
                    try { CoTaskMemFree(outBuf); } catch { }
                }
            }
        }
    }
}
