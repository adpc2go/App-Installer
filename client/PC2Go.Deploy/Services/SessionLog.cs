using System;
using System.IO;
using System.Text;

namespace PC2Go.Deploy.Services
{
    /// <summary>
    /// The on-disk copy first - it must survive even if the UI half throws. One file per session
    /// under a folder the cache sweep never touches, so a report of "it failed on their machine"
    /// still has something to read a week later.
    /// </summary>
    public sealed class SessionLog
    {
        public string Path { get; private set; }
        public event Action<string, string> Line;   // (timestamp, message) on the caller's thread

        public SessionLog(string baseUrl, bool elevated)
        {
            try
            {
                var dir = System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "PC2GoDeploy-Logs");
                Directory.CreateDirectory(dir);
                Path = System.IO.Path.Combine(dir, "session-" + DateTime.Now.ToString("yyyyMMdd-HHmmss") + ".log");
                File.AppendAllText(Path, Header(baseUrl, elevated), new UTF8Encoding(false));
            }
            catch { Path = null; }
        }

        public static string Header(string baseUrl, bool elevated)
        {
            var sb = new StringBuilder();
            sb.AppendLine(App.AppTitle + " (" + App.BuildTag + ") - session started " + DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss"));
            sb.AppendLine("Machine   : " + Environment.MachineName);
            sb.AppendLine("User      : " + Environment.UserName + "   (elevated: " + (elevated ? "yes" : "no") + ")");
            sb.AppendLine("OS        : " + Environment.OSVersion.VersionString);
            sb.AppendLine("Client    : compiled, .NET " + Environment.Version);
            sb.AppendLine("Server    : " + baseUrl);
            sb.AppendLine("------------------------------------------------------------");
            return sb.ToString();
        }

        public void Add(string message)
        {
            var ts = DateTime.Now;
            if (Path != null)
            {
                try { File.AppendAllText(Path, "[" + ts.ToString("yyyy-MM-dd HH:mm:ss") + "] " + message + Environment.NewLine, new UTF8Encoding(false)); }
                catch { }
            }
            var h = Line;
            if (h != null) h(ts.ToString("HH:mm:ss"), message);
        }
    }
}
