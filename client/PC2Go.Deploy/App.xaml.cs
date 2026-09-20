using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Security.Principal;
using System.Threading;
using System.Windows;
using PC2Go.Deploy.Services;

namespace PC2Go.Deploy
{
    /// <summary>
    /// Startup: the same command line go.ps1 gives AppDeploy.ps1, the same single-instance mutex,
    /// the same elevation decision. Everything that used to happen in the first 300 lines of the
    /// script happens here, before a window exists.
    /// </summary>
    public partial class App : Application
    {
        public const string AppTitle = "PC2Go App Installer";
        // bumped on every change; written to the session log header and the run records
        public const string BuildTag = "client 23";

        public static Options Opts { get; private set; }
        public static bool Elevated { get; private set; }
        private static Mutex _single;

        protected override void OnStartup(StartupEventArgs e)
        {
            base.OnStartup(e);
            ShutdownMode = ShutdownMode.OnExplicitShutdown;
            Opts = Options.Parse(e.Args);

            // No window, no elevation, no mutex: a probe the test suites read back. It answers
            // "what would the client do?" with the real code paths and nothing on screen.
            if (Opts.SelfTest)
            {
                try { SelfTest.Run(Opts); Shutdown(0); }
                catch (Exception ex)
                {
                    try { File.WriteAllText(Opts.SelfTestOut ?? "selftest-error.txt", ex.ToString()); } catch { }
                    Shutdown(2);
                }
                return;
            }
            // The download path alone, headless: a test puts a faulty server in front of it and may
            // kill this process mid-file to prove the journal resumes it.
            if (!string.IsNullOrEmpty(Opts.DownloadUrl))
            {
                Shutdown(DownloadProbe.Run(Opts));
                return;
            }

            Elevated = IsElevated();

            // Decide elevation once, like AppDeploy.ps1's Test-IsAdminMember: ask the GROUP, not
            // the token. The token of a filtered administrator may not carry the Administrators
            // SID at all. go.ps1 passes -NoSelfElevate when it has already decided.
            if (!Elevated && !Opts.NoSelfElevate && Elevation.IsAdminMember())
            {
                try
                {
                    var psi = new ProcessStartInfo
                    {
                        FileName = ExePath(),
                        Arguments = Opts.ToArguments() + " -NoSelfElevate",
                        UseShellExecute = true,
                        Verb = "runas",
                        WorkingDirectory = Path.GetDirectoryName(ExePath()) ?? ""
                    };
                    Process.Start(psi);
                    Shutdown(0);
                    return;
                }
                catch
                {
                    // declined, or elevation unavailable: run as we are, the way the script does
                }
            }

            // One instance per machine - the same name the script uses, so the two clients can
            // never run one queue at once either.
            bool created;
            _single = new Mutex(true, @"Local\PC2GoAppInstaller", out created);
            if (!created)
            {
                MessageBox.Show("PC2Go App Installer is already running on this machine.", AppTitle,
                                MessageBoxButton.OK, MessageBoxImage.Information);
                Shutdown(0);
                return;
            }

            // A crash must leave a file behind, or "it just closed" is all anyone can report.
            DispatcherUnhandledException += (s, ev) =>
            {
                var path = WriteCrash(ev.Exception);
                try
                {
                    MessageBox.Show("PC2Go App Installer hit an error it could not recover from:\n\n" + ev.Exception.Message +
                                    (path != null ? "\n\nDetails were written to:\n" + path : ""), AppTitle,
                                    MessageBoxButton.OK, MessageBoxImage.Error);
                }
                catch { }
                ev.Handled = true;
                Shutdown(1);
            };
            AppDomain.CurrentDomain.UnhandledException += (s, ev) => { WriteCrash(ev.ExceptionObject as Exception); };

            var win = new MainWindow();
            MainWindow = win;
            ShutdownMode = ShutdownMode.OnMainWindowClose;
            win.Show();
        }

        public static string WriteCrash(Exception ex)
        {
            try
            {
                var dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "PC2GoDeploy");
                Directory.CreateDirectory(dir);
                var path = Path.Combine(dir, "crash-" + DateTime.Now.ToString("yyyyMMdd-HHmmss") + ".txt");
                File.WriteAllText(path, AppTitle + " - " + BuildTag + " - " + DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + Environment.NewLine +
                                        (ex == null ? "(no exception object)" : ex.ToString()));
                return path;
            }
            catch { return null; }
        }

        public static string ExePath()
        {
            try { return Process.GetCurrentProcess().MainModule.FileName; }
            catch { return typeof(App).Assembly.Location; }
        }

        private static bool IsElevated()
        {
            try
            {
                using (var id = WindowsIdentity.GetCurrent())
                    return new WindowsPrincipal(id).IsInRole(WindowsBuiltInRole.Administrator);
            }
            catch { return false; }
        }
    }

    /// <summary>The script's param block. Unknown switches are ignored, as PowerShell would not - but a
    /// bootstrap one release ahead of the client must not stop it from starting.</summary>
    public sealed class Options
    {
        public string BaseUrl = "https://apps.example.com";
        public bool KeepCache;
        public bool NoSelfElevate;
        public bool Timing;
        public bool SelfTest;
        public string SelfTestOut;
        public string SelfTestCatalog;
        // -Download: the download path headless (see DownloadProbe); -Out names its report
        public string DownloadUrl, DownloadDest;
        public long DownloadSize, DownloadChunkFloor;
        public int DownloadStreams;
        // Harness seams, like the script's -TestWatchRoots: tick these ids and press Install the
        // moment the catalog is up, and leave when the batch has ended. Never set by go.ps1.
        public string[] AutoInstall = new string[0];
        public string[] AutoUninstall = new string[0];
        public bool AutoWipe, AutoForce;
        public bool AutoClose;
        public string StartTab;

        public static Options Parse(IList<string> args)
        {
            var o = new Options();
            for (int i = 0; i < args.Count; i++)
            {
                var a = args[i];
                string Next() { return (i + 1 < args.Count) ? args[++i] : ""; }
                switch (a.ToLowerInvariant())
                {
                    case "-baseurl": o.BaseUrl = Next().Trim().TrimEnd('/'); break;
                    case "-keepcache": o.KeepCache = true; break;
                    case "-noselfelevate": o.NoSelfElevate = true; break;
                    case "-timing": o.Timing = true; break;
                    case "-selftest": o.SelfTest = true; break;
                    case "-out": o.SelfTestOut = Next(); break;
                    case "-catalog": o.SelfTestCatalog = Next(); break;
                    case "-download": o.DownloadUrl = Next(); break;
                    case "-dest": o.DownloadDest = Next(); break;
                    case "-size": long.TryParse(Next(), out o.DownloadSize); break;
                    case "-streams": int.TryParse(Next(), out o.DownloadStreams); break;
                    case "-chunkfloor": long.TryParse(Next(), out o.DownloadChunkFloor); break;
                    case "-autoinstall": o.AutoInstall = Next().Split(new[] { ',' }, StringSplitOptions.RemoveEmptyEntries); break;
                    case "-autoclose": o.AutoClose = true; break;
                    case "-autouninstall": o.AutoUninstall = Next().Split(new[] { ',' }, StringSplitOptions.RemoveEmptyEntries); break;
                    case "-autowipe": o.AutoWipe = true; break;
                    case "-autoforce": o.AutoForce = true; break;
                    case "-starttab": o.StartTab = Next(); break;
                }
            }
            return o;
        }

        public string ToArguments()
        {
            var s = "-BaseUrl \"" + BaseUrl + "\"";
            if (KeepCache) s += " -KeepCache";
            if (Timing) s += " -Timing";
            return s;
        }
    }
}
