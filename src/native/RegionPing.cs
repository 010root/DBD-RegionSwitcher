using System;
using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using System.Threading;
using System.Threading.Tasks;
public static class RegionPing {
    // ips[i] null/empty = no address (shown as no result). Returns best connect time per region in ms, -1 = timeout.
    // Runs on the thread pool; the window polls IsCompleted and stays responsive.
    public static Task<int[]> Start(string[] ips, int port, int samples, int timeoutMs) {
        return Task.Run(() => {
            int n = ips.Length;
            int[] best = new int[n];
            for (int i = 0; i < n; i++) best[i] = -1;
            for (int s = 0; s < samples; s++) {
                TcpClient[] cl = new TcpClient[n];
                Task[] tasks = new Task[n];
                for (int i = 0; i < n; i++) {
                    // no address, or no answer in the first round: don't wait out the timeout again
                    if (string.IsNullOrEmpty(ips[i]) || (s > 0 && best[i] < 0)) {
                        tasks[i] = Task.FromResult(0);
                        continue;
                    }
                    int k = i;
                    Stopwatch sw = Stopwatch.StartNew();
                    cl[i] = new TcpClient(AddressFamily.InterNetwork);
                    tasks[i] = cl[i].ConnectAsync(IPAddress.Parse(ips[i]), port).ContinueWith(t => {
                        if (t.Status == TaskStatus.RanToCompletion) {
                            int ms = (int)sw.ElapsedMilliseconds;
                            lock (best) { if (best[k] < 0 || ms < best[k]) best[k] = ms; }
                        }
                    }, TaskContinuationOptions.ExecuteSynchronously);
                }
                Task.WaitAll(tasks, timeoutMs);
                foreach (TcpClient c in cl) { try { if (c != null) c.Close(); } catch { } }
            }
            return best;
        });
    }
}
