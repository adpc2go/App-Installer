using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Windows.Media.Imaging;

namespace PC2Go.Deploy.Services
{
    public sealed class FixDef
    {
        public string Id, Name, Group, Hint;
        public FixDef(string id, string name, string group, string hint) { Id = id; Name = name; Group = group; Hint = hint; }
    }

    public sealed class PanelDef
    {
        public string Name, Cmd, Args, Icon;
        public PanelDef(string name, string cmd, string args = "", string icon = "") { Name = name; Cmd = cmd; Args = args; Icon = icon; }
    }

    /// <summary>
    /// The Toolbox tables, verbatim from the script. Fixes run elevated through the same one-UAC
    /// queue as everything else; panels are shortcuts launched unelevated straight from the GUI -
    /// Windows elevates them itself if they need it, and routing them through the worker would
    /// cost a pointless UAC prompt.
    /// </summary>
    public static class Toolbox
    {
        public static readonly FixDef[] FixDefs =
        {
            new FixDef("autologon", "AutoLogon - Run",                "Fixes",         "sign in automatically at boot - asks for the account"),
            new FixDef("mpo",       "Multiplane Overlay - Disable",   "Fixes",         "fixes GPU flicker/stutter on some panels - costs performance on healthy machines, run only on a symptom"),
            new FixDef("netreset",  "Network - Reset",                "Fixes",         "winsock + TCP/IP stack, DNS cache, DHCP lease. Needs a reboot"),
            new FixDef("s3sleep",   "S3 Sleep - Force",               "Fixes",         "fixes Modern Standby laptops that drain or overheat asleep - hardware-dependent, can break wake"),
            new FixDef("ntp",       "NTP Server - Enable",            "Fixes",         "point the clock at time.windows.com and resync now"),
            new FixDef("sfc",       "System Corruption Scan - Run",   "Fixes",         "sfc /scannow then DISM RestoreHealth - can take 30 minutes"),
            new FixDef("searchrebuild", "Search Index - Rebuild",     "Fixes",         "stops Windows Search, drops the index and lets it rebuild - search is patchy for an hour"),
            new FixDef("restart",   "Restart Now - 60 Second Warning", "Fixes",        "restarts this PC in 60 seconds with a message on screen - shutdown /a cancels it"),
            new FixDef("wureset",   "Windows Update - Reset",         "Fixes",         "clears the update cache and re-registers the services"),
            new FixDef("winget",    "WinGet - Reinstall",             "Fixes",         "re-register App Installer, then fetch it if that fails"),
            new FixDef("openssh",   "OpenSSH Server - Enable",        "Remote Access", "installs sshd, starts it, opens port 22 - a remote way in"),
            new FixDef("slowpc",    "Slow PC - Diagnose",             "Diagnostics",   "reads seven layers in order and says which one is the problem - changes nothing"),
        };

        // name -> what to launch, plus where its real Windows icon lives. Most .cpl applets carry
        // their own icon at index 0; the exceptions are measured, not guessed:
        //   firewall.cpl  is a stub with no icon  -> FirewallControlPanel.dll
        //   compmgmt.msc  is XML, .msc never has one -> mmcndmgr.dll, the MMC node manager
        public static readonly PanelDef[] PanelDefs =
        {
            new PanelDef("Computer Management",       "compmgmt.msc", "", "mmcndmgr.dll"),
            new PanelDef("Control Panel",             "control.exe"),
            new PanelDef("Programs and Features",     "appwiz.cpl"),
            new PanelDef("Network Connections",       "ncpa.cpl"),
            new PanelDef("Windows Defender Firewall", "firewall.cpl", "", "FirewallControlPanel.dll"),
            new PanelDef("System Properties",         "sysdm.cpl"),
            new PanelDef("Power Panel",               "powercfg.cpl"),
            new PanelDef("Sound Settings",            "mmsys.cpl"),
            new PanelDef("Mouse Properties",          "main.cpl"),
            new PanelDef("Printer Panel",             "control.exe", "printers", "printui.dll"),
            new PanelDef("Region",                    "intl.cpl"),
            new PanelDef("Time and Date",             "timedate.cpl"),
            new PanelDef("Security and Maintenance",  "wscui.cpl"),
            new PanelDef("Windows Restore",           "rstrui.exe"),
        };

        [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
        private static extern uint ExtractIconEx(string file, int index, IntPtr[] large, IntPtr[] small, uint count);
        [DllImport("user32.dll")]
        private static extern bool DestroyIcon(IntPtr handle);

        /// <summary>The real Windows icon for a panel: the module named for it, then the command itself, then shell32's generic control-panel icon (index 21).</summary>
        public static BitmapImage PanelIcon(PanelDef p)
        {
            var sources = new List<KeyValuePair<string, int>>();
            if (!string.IsNullOrEmpty(p.Icon)) sources.Add(new KeyValuePair<string, int>(p.Icon, 0));
            sources.Add(new KeyValuePair<string, int>(p.Cmd, 0));
            sources.Add(new KeyValuePair<string, int>("shell32.dll", 21));
            foreach (var s in sources)
            {
                var img = ModuleIcon(s.Key, s.Value);
                if (img != null) return img;
            }
            return null;
        }

        /// <summary>One icon out of a module, 32 px, as a frozen image - or null when the module has none there.</summary>
        public static BitmapImage ModuleIcon(string file, int index)
        {
            try
            {
                var path = file;
                if (!Path.IsPathRooted(path))
                {
                    var sys = Path.Combine(Environment.SystemDirectory, file);
                    if (File.Exists(sys)) path = sys;
                }
                if (!File.Exists(path)) return null;
                var large = new IntPtr[1];
                var small = new IntPtr[1];
                var n = ExtractIconEx(path, index, large, small, 1);
                if (n == 0 || n == uint.MaxValue || large[0] == IntPtr.Zero) { if (small[0] != IntPtr.Zero) DestroyIcon(small[0]); return null; }
                try
                {
                    using (var ico = System.Drawing.Icon.FromHandle(large[0]))
                    using (var bmp = ico.ToBitmap())
                    using (var ms = new MemoryStream())
                    {
                        bmp.Save(ms, System.Drawing.Imaging.ImageFormat.Png);
                        var img = new BitmapImage();
                        using (var src = new MemoryStream(ms.ToArray()))
                        {
                            img.BeginInit();
                            img.CacheOption = BitmapCacheOption.OnLoad;
                            img.StreamSource = src;
                            img.EndInit();
                        }
                        img.Freeze();
                        return img;
                    }
                }
                finally
                {
                    DestroyIcon(large[0]);
                    if (small[0] != IntPtr.Zero) DestroyIcon(small[0]);
                }
            }
            catch { return null; }
        }
    }
}
