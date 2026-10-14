using System;
using System.Diagnostics;
using System.IO;
using System.Windows.Forms;

internal static class CampusAutoLoginLauncher
{
    [STAThread]
    private static int Main(string[] args)
    {
        try
        {
            string root = AppDomain.CurrentDomain.BaseDirectory;
            string mode = args.Length == 0 ? "" : args[0];
            if (mode != "" && mode != "--watch" && mode != "--uninstall")
                throw new ArgumentException("不支持的启动参数。");
            string script = Path.Combine(root, mode == "--watch" ? "campus-login.ps1" : "manager.ps1");
            if (!File.Exists(script)) throw new FileNotFoundException("程序文件不完整，请先解压整个安装包。", script);
            string powershell = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), @"WindowsPowerShell\v1.0\powershell.exe");
            var info = new ProcessStartInfo(powershell);
            info.UseShellExecute = false;
            info.CreateNoWindow = true;
            info.WindowStyle = ProcessWindowStyle.Hidden;
            info.WorkingDirectory = root;
            info.Arguments = "-NoProfile -STA -ExecutionPolicy Bypass -File \"" + script + "\"";
            if (mode == "--watch") info.Arguments += " -Watch";
            if (mode == "--uninstall") info.Arguments += " -Uninstall";
            using (var process = Process.Start(info)) { }
            return 0;
        }
        catch (Exception error)
        {
            MessageBox.Show("启动失败：" + error.Message, "校园网自动登录", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
    }
}

