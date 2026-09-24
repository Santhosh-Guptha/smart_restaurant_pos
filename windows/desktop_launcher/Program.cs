using System;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;

namespace SmartDine
{
    static class Program
    {
        private const int Port = 8090;
        private static HttpListener _listener;
        private static string _webRootDir;
        private static bool _isRunning = true;

        [STAThread]
        static void Main(string[] args)
        {
            try
            {
                _webRootDir = ResolveWebRoot();

                bool portInUse = IsPortInUse(Port);
                if (!portInUse)
                {
                    StartHttpServer(Port, _webRootDir);
                }

                // Wait briefly for server to bind if just started
                if (!portInUse)
                {
                    Thread.Sleep(300);
                }

                // Launch Edge/Chrome in App Mode
                Process browserProc = LaunchAppWindow("http://localhost:" + Port + "/pos/");

                if (browserProc != null && !portInUse)
                {
                    // Clean up server when browser window closes
                    browserProc.WaitForExit();
                    StopHttpServer();
                }
            }
            catch (Exception ex)
            {
                // Fallback: If exception occurs, try opening default browser
                try
                {
                    Process.Start("https://smartdine-pos.web.app/pos/");
                }
                catch { }
            }
        }

        private static string ResolveWebRoot()
        {
            string baseDir = AppDomain.CurrentDomain.BaseDirectory;

            // Priority 1: Check hosting_public folder relative to exe
            string hostingPos = Path.Combine(baseDir, "hosting_public");
            if (Directory.Exists(hostingPos) && File.Exists(Path.Combine(hostingPos, "pos", "index.html")))
            {
                return hostingPos;
            }

            // Priority 2: Check build\web folder
            string buildWeb = Path.Combine(baseDir, "build", "web");
            if (Directory.Exists(buildWeb) && File.Exists(Path.Combine(buildWeb, "index.html")))
            {
                return buildWeb;
            }

            // Priority 3: Check parent directory (e.g. if run from a bin or release subfolder)
            DirectoryInfo parent = Directory.GetParent(baseDir);
            if (parent != null)
            {
                string parentHosting = Path.Combine(parent.FullName, "hosting_public");
                if (Directory.Exists(parentHosting) && File.Exists(Path.Combine(parentHosting, "pos", "index.html")))
                {
                    return parentHosting;
                }

                string parentBuild = Path.Combine(parent.FullName, "build", "web");
                if (Directory.Exists(parentBuild) && File.Exists(Path.Combine(parentBuild, "index.html")))
                {
                    return parentBuild;
                }
            }

            // Default to base directory
            return baseDir;
        }

        private static bool IsPortInUse(int port)
        {
            try
            {
                using (var client = new TcpClient())
                {
                    var result = client.BeginConnect("127.0.0.1", port, null, null);
                    bool success = result.AsyncWaitHandle.WaitOne(300);
                    if (success)
                    {
                        client.EndConnect(result);
                        return true;
                    }
                }
            }
            catch { }
            return false;
        }

        private static void StartHttpServer(int port, string rootDir)
        {
            try
            {
                _listener = new HttpListener();
                _listener.Prefixes.Add("http://localhost:" + port + "/");
                _listener.Prefixes.Add("http://127.0.0.1:" + port + "/");
                _listener.Start();

                Thread listenerThread = new Thread(ListenLoop);
                listenerThread.IsBackground = true;
                listenerThread.Start();
            }
            catch (Exception)
            {
                // If prefix reservation required, fallback to 127.0.0.1 only
                try
                {
                    _listener = new HttpListener();
                    _listener.Prefixes.Add("http://127.0.0.1:" + port + "/");
                    _listener.Start();

                    Thread listenerThread = new Thread(ListenLoop);
                    listenerThread.IsBackground = true;
                    listenerThread.Start();
                }
                catch { }
            }
        }

        private static void StopHttpServer()
        {
            _isRunning = false;
            try
            {
                if (_listener != null && _listener.IsListening)
                {
                    _listener.Stop();
                    _listener.Close();
                }
            }
            catch { }
        }

        private static void ListenLoop()
        {
            while (_isRunning && _listener != null && _listener.IsListening)
            {
                try
                {
                    HttpListenerContext context = _listener.GetContext();
                    ThreadPool.QueueUserWorkItem(state => ProcessRequest((HttpListenerContext)state), context);
                }
                catch
                {
                    if (!_isRunning) break;
                }
            }
        }

        private static void ProcessRequest(HttpListenerContext context)
        {
            try
            {
                HttpListenerRequest req = context.Request;
                HttpListenerResponse resp = context.Response;

                // Always allow CORS for local integration
                resp.AddHeader("Access-Control-Allow-Origin", "*");
                resp.AddHeader("Access-Control-Allow-Methods", "GET, POST, OPTIONS, HEAD");
                resp.AddHeader("Access-Control-Allow-Headers", "*");

                if (req.HttpMethod == "OPTIONS")
                {
                    resp.StatusCode = 200;
                    resp.Close();
                    return;
                }

                string rawUrl = req.Url.AbsolutePath;

                // Route root to /pos/ or pos/index.html
                if (string.IsNullOrEmpty(rawUrl) || rawUrl == "/")
                {
                    resp.Redirect("/pos/");
                    resp.Close();
                    return;
                }

                string relativePath = rawUrl.TrimStart('/').Replace('/', Path.DirectorySeparatorChar);
                string filePath = Path.Combine(_webRootDir, relativePath);

                // If path is a directory, look for index.html inside it
                if (Directory.Exists(filePath))
                {
                    filePath = Path.Combine(filePath, "index.html");
                }
                else if (!File.Exists(filePath))
                {
                    // Fallback routing for SPA deep paths under /pos/
                    if (rawUrl.StartsWith("/pos/"))
                    {
                        string posIndex = Path.Combine(_webRootDir, "pos", "index.html");
                        if (File.Exists(posIndex))
                        {
                            filePath = posIndex;
                        }
                        else
                        {
                            // If _webRootDir itself is build/web
                            string rootIndex = Path.Combine(_webRootDir, "index.html");
                            if (File.Exists(rootIndex)) filePath = rootIndex;
                        }
                    }
                }

                if (File.Exists(filePath))
                {
                    byte[] bytes = File.ReadAllBytes(filePath);
                    resp.ContentType = GetMimeType(filePath);
                    resp.ContentLength64 = bytes.Length;
                    resp.StatusCode = 200;
                    resp.OutputStream.Write(bytes, 0, bytes.Length);
                }
                else
                {
                    resp.StatusCode = 404;
                    byte[] err = Encoding.UTF8.GetBytes("File Not Found");
                    resp.OutputStream.Write(err, 0, err.Length);
                }

                resp.OutputStream.Close();
            }
            catch { }
        }

        private static string GetMimeType(string path)
        {
            string ext = Path.GetExtension(path).ToLowerInvariant();
            switch (ext)
            {
                case ".html": case ".htm": return "text/html; charset=utf-8";
                case ".js": case ".mjs": return "application/javascript; charset=utf-8";
                case ".json": return "application/json; charset=utf-8";
                case ".css": return "text/css; charset=utf-8";
                case ".png": return "image/png";
                case ".jpg": case ".jpeg": return "image/jpeg";
                case ".gif": return "image/gif";
                case ".svg": return "image/svg+xml";
                case ".ico": return "image/x-icon";
                case ".wasm": return "application/wasm";
                case ".ttf": return "font/ttf";
                case ".otf": return "font/otf";
                case ".woff": return "font/woff";
                case ".woff2": return "font/woff2";
                case ".pdf": return "application/pdf";
                default: return "application/octet-stream";
            }
        }

        private static Process LaunchAppWindow(string url)
        {
            string edgePath = FindEdgeExecutable();
            if (!string.IsNullOrEmpty(edgePath))
            {
                return StartAppProcess(edgePath, "--app=\"" + url + "\"");
            }

            string chromePath = FindChromeExecutable();
            if (!string.IsNullOrEmpty(chromePath))
            {
                return StartAppProcess(chromePath, "--app=\"" + url + "\"");
            }

            // Fallback: Default system browser
            return Process.Start(new ProcessStartInfo(url) { UseShellExecute = true });
        }

        private static Process StartAppProcess(string exePath, string args)
        {
            var psi = new ProcessStartInfo
            {
                FileName = exePath,
                Arguments = args,
                UseShellExecute = false
            };
            return Process.Start(psi);
        }

        private static string FindEdgeExecutable()
        {
            string[] paths = {
                Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86), "Microsoft\\Edge\\Application\\msedge.exe"),
                Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "Microsoft\\Edge\\Application\\msedge.exe")
            };

            foreach (var p in paths)
            {
                if (File.Exists(p)) return p;
            }
            return null;
        }

        private static string FindChromeExecutable()
        {
            string[] paths = {
                Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "Google\\Chrome\\Application\\chrome.exe"),
                Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86), "Google\\Chrome\\Application\\chrome.exe"),
                Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Google\\Chrome\\Application\\chrome.exe")
            };

            foreach (var p in paths)
            {
                if (File.Exists(p)) return p;
            }
            return null;
        }
    }
}
