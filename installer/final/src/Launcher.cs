using System;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Reflection;

internal static class Program
{
    private static int Main(string[] args)
    {
        string baseDir = AppDomain.CurrentDomain.BaseDirectory;
        string script = Path.Combine(baseDir, "install.ps1");
        string temp = null;

        if (!File.Exists(script))
        {
            temp = Path.Combine(Path.GetTempPath(), "vibe-mode-setup-" + Guid.NewGuid().ToString("N").Substring(0, 8));
            Directory.CreateDirectory(temp);
            using (Stream stream = Assembly.GetExecutingAssembly().GetManifestResourceStream("payload.zip"))
            {
                if (stream == null)
                {
                    Console.Error.WriteLine("Embedded payload is missing.");
                    Pause();
                    return 2;
                }
                string zip = Path.Combine(temp, "payload.zip");
                using (FileStream file = File.Create(zip))
                {
                    stream.CopyTo(file);
                }
                ZipFile.ExtractToDirectory(zip, temp);
                try { File.Delete(zip); } catch { }
            }
            script = Path.Combine(temp, "install.ps1");
        }

        string source = temp != null ? temp : baseDir;
        source = source.TrimEnd('\\');
        string arguments = "-NoProfile -ExecutionPolicy Bypass -File \"" + script + "\" -SourceDir \"" + source + "\"";
        foreach (string arg in args)
        {
            if (arg.IndexOf(' ') >= 0) { arguments += " \"" + arg.Replace("\"", "\\\"") + "\""; }
            else { arguments += " " + arg; }
        }
        if (Environment.GetEnvironmentVariable("VIBE_SETUP_DEBUG") == "1")
        {
            Console.WriteLine("powershell.exe " + arguments);
        }
        ProcessStartInfo info = new ProcessStartInfo("powershell.exe", arguments);
        info.UseShellExecute = false;
        info.WorkingDirectory = source;

        int code;
        try
        {
            Process process = Process.Start(info);
            process.WaitForExit();
            code = process.ExitCode;
        }
        catch (Exception error)
        {
            Console.Error.WriteLine("Could not start PowerShell: " + error.Message);
            Pause();
            return 3;
        }

        if (temp != null)
        {
            try { Directory.Delete(temp, true); } catch { }
        }

        if (code != 0)
        {
            Console.WriteLine();
            Console.WriteLine("Setup exited with code " + code + ".");
            Pause();
        }
        return code;
    }

    private static void Pause()
    {
        try
        {
            Console.WriteLine("Press any key to close.");
            Console.ReadKey(true);
        }
        catch { }
    }
}
