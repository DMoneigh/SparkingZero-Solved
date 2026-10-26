using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Forms;

namespace DezsMinion
{
    public sealed class ModMenu : Form
    {
        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool RegisterHotKey(IntPtr window, int id, uint modifiers, uint key);
        [DllImport("user32.dll")]
        private static extern bool UnregisterHotKey(IntPtr window, int id);
        [DllImport("user32.dll")]
        private static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")]
        private static extern uint GetWindowThreadProcessId(IntPtr window, out uint process);

        private readonly string bridge;
        private readonly string executable;
        private readonly string session = Guid.NewGuid().ToString("N");
        private readonly Dictionary<string, CheckBox> toggles = new Dictionary<string, CheckBox>();
        private readonly Timer timer = new Timer();
        private readonly Label connection = new Label();
        private readonly Label readout = new Label();
        private readonly CheckBox armed = new CheckBox();
        private readonly ComboBox side = new ComboBox();
        private readonly NumericUpDown fps = new NumericUpDown();
        private readonly CheckBox unlimited = new CheckBox();
        private readonly Button suspend = new Button();
        private readonly NotifyIcon tray = new NotifyIcon();
        private readonly Color orange = Color.FromArgb(255, 120, 47);
        private FileStream ownership;
        private long sequence;
        private string runtime = "";
        private bool registered;
        private bool changing;
        private string lastIoError = "";
        private long ioFailureSince;
        private uint gamePid;
        private int polls;
        private long lastRuntimeResponse = Epoch();

        private ModMenu(string modDirectory, string gameExecutable)
        {
            bridge = Path.Combine(modDirectory, "Bridge");
            executable = Path.GetFullPath(gameExecutable);
            Directory.CreateDirectory(bridge);
            ownership = new FileStream(Path.Combine(bridge, "panel.lock"), FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
            Text = "Dez's Minion | Sparking Zero";
            ClientSize = new Size(510, 650);
            MinimumSize = new Size(526, 689);
            MaximumSize = new Size(526, 689);
            FormBorderStyle = FormBorderStyle.FixedSingle;
            MaximizeBox = false;
            StartPosition = FormStartPosition.CenterScreen;
            BackColor = Color.FromArgb(20, 21, 24);
            ForeColor = Color.FromArgb(239, 238, 235);
            Font = new Font("Segoe UI", 10);
            TopMost = true;
            AddLabel("SPARKING ZERO  //  NATIVE CONTROLS", 24, 21, 460, 22, 10, orange);
            AddLabel("Your rules. Your power.", 22, 48, 465, 40, 23, ForeColor);
            AddLabel("OFFLINE ONLY  /  F6 TO SHOW OR HIDE", 25, 94, 450, 20, 9, Color.Gray);
            connection.SetBounds(24, 126, 462, 56);
            connection.ForeColor = Color.Silver;
            connection.Text = "Waiting for UE4SS. Launch the game normally.";
            Controls.Add(connection);

            armed.Text = "Enable controls for this offline session";
            armed.SetBounds(24, 191, 460, 28);
            armed.ForeColor = orange;
            armed.CheckedChanged += Changed;
            Controls.Add(armed);
            string[] keys = { "health", "ki", "sparking", "fps", "skill" };
            string[] names = { "Max Health", "Max Ki", "Unlimited Sparking Mode", "Control Frame Rate", "Max Skill Count Bars" };
            for (int i = 0; i < keys.Length; i++)
            {
                CheckBox control = new CheckBox();
                control.Text = names[i];
                control.SetBounds(27, 235 + i * 39, 330, 27);
                control.CheckedChanged += Changed;
                toggles.Add(keys[i], control);
                Controls.Add(control);
            }
            AddLabel("FPS cap", 26, 438, 70, 24, 10, Color.Silver);
            fps.SetBounds(100, 436, 82, 28);
            fps.Minimum = 30;
            fps.Maximum = 240;
            fps.Value = 60;
            fps.ValueChanged += Changed;
            Controls.Add(fps);
            unlimited.Text = "Uncapped";
            unlimited.SetBounds(197, 437, 109, 27);
            unlimited.CheckedChanged += Changed;
            Controls.Add(unlimited);
            side.SetBounds(340, 436, 140, 28);
            side.DropDownStyle = ComboBoxStyle.DropDownList;
            side.Items.AddRange(new object[] { "Player 1 (side 0)", "Player 2 (side 1)" });
            side.SelectedIndex = 0;
            side.SelectedIndexChanged += Changed;
            Controls.Add(side);
            readout.SetBounds(24, 482, 462, 44);
            readout.ForeColor = Color.DarkGray;
            readout.Font = new Font("Consolas", 9);
            readout.Text = "No applied values yet.";
            Controls.Add(readout);
            suspend.Text = "DISABLE ALL";
            suspend.SetBounds(24, 541, 224, 36);
            suspend.FlatStyle = FlatStyle.Flat;
            suspend.ForeColor = orange;
            suspend.Click += delegate { Disarm(); Publish(); };
            Controls.Add(suspend);
            Button hide = new Button();
            hide.Text = "Hide menu [F6]";
            hide.SetBounds(263, 541, 223, 36);
            hide.FlatStyle = FlatStyle.Flat;
            hide.Click += delegate { Hide(); };
            Controls.Add(hide);
            AddLabel("Closing the panel releases continuous controls.\nUse borderless/windowed mode to see this external overlay.", 24, 594, 470, 42, 9, Color.Gray);
            // PowerShell may already own windows; configure our controls, not the host's global default.
            foreach (Control control in Controls)
            {
                Label label = control as Label;
                if (label != null) label.UseCompatibleTextRendering = false;
                ButtonBase button = control as ButtonBase;
                if (button != null) button.UseCompatibleTextRendering = false;
            }
            tray.Icon = SystemIcons.Application;
            tray.Text = "Dez's Minion - F6 controls";
            tray.Visible = true;
            tray.DoubleClick += delegate { ShowPanel(); };
            ContextMenuStrip menu = new ContextMenuStrip();
            menu.Items.Add("Show controls", null, delegate { ShowPanel(); });
            menu.Items.Add("Disable all", null, delegate { Disarm(); Publish(); });
            menu.Items.Add("Exit", null, delegate { Close(); });
            tray.ContextMenuStrip = menu;
            timer.Interval = 250;
            timer.Tick += Poll;
            Shown += delegate
            {
                registered = RegisterHotKey(Handle, 1, 0x4000, (uint)Keys.F6);
                if (!registered)
                    MessageBox.Show(this, "F6 is already registered by another application. Use the tray icon to reopen this panel.", Text, MessageBoxButtons.OK, MessageBoxIcon.Warning);
                Publish();
                timer.Start();
            };
            FormClosing += delegate
            {
                timer.Stop();
                Disarm();
                Publish();
                if (registered) UnregisterHotKey(Handle, 1);
                tray.Visible = false;
                tray.Dispose();
                ownership.Dispose();
            };
        }

        private void AddLabel(string text, int x, int y, int width, int height, float size, Color color)
        {
            Label label = new Label();
            label.Text = text;
            label.SetBounds(x, y, width, height);
            label.Font = new Font("Segoe UI", size);
            label.ForeColor = color;
            Controls.Add(label);
        }

        private void Changed(object sender, EventArgs args)
        {
            if (changing) return;
            sequence++;
            fps.Enabled = !unlimited.Checked;
            Publish();
        }

        private void Disarm()
        {
            changing = true;
            armed.Checked = false;
            foreach (CheckBox toggle in toggles.Values) toggle.Checked = false;
            changing = false;
            sequence++;
        }

        private static long Epoch()
        {
            return (long)(DateTime.UtcNow - new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc)).TotalSeconds;
        }

        private void Publish()
        {
            StringBuilder body = new StringBuilder();
            body.AppendLine("protocol=1");
            body.AppendLine("session=" + session);
            body.AppendLine("sequence=" + sequence.ToString(CultureInfo.InvariantCulture));
            body.AppendLine("heartbeat=" + Epoch().ToString(CultureInfo.InvariantCulture));
            body.AppendLine("armed=" + (armed.Checked ? "1" : "0"));
            body.AppendLine("side=" + side.SelectedIndex.ToString(CultureInfo.InvariantCulture));
            body.AppendLine("frame_rate=" + (unlimited.Checked ? "0" : fps.Value.ToString(CultureInfo.InvariantCulture)));
            foreach (KeyValuePair<string, CheckBox> pair in toggles)
                body.AppendLine(pair.Key + "=" + (pair.Value.Checked ? "1" : "0"));
            string temporary = Path.Combine(bridge, "request-" + session + ".tmp");
            string destination = Path.Combine(bridge, "request.txt");
            try
            {
                File.WriteAllText(temporary, body.ToString(), new UTF8Encoding(false));
                for (int attempt = 0; ; attempt++)
                {
                    try
                    {
                        if (File.Exists(destination)) File.Replace(temporary, destination, null);
                        else File.Move(temporary, destination);
                        break;
                    }
                    catch (IOException error)
                    {
                        if (!IsSharingViolation(error) || attempt == 3) throw;
                        // Lua's brief CRT read holds a handle without delete sharing.
                        System.Threading.Thread.Sleep(5);
                    }
                }
                lastIoError = "";
                ioFailureSince = 0;
            }
            catch (IOException error) { IoFailure(error.Message, IsSharingViolation(error)); }
            catch (UnauthorizedAccessException error) { IoFailure(error.Message, false); }
        }

        private static bool IsSharingViolation(IOException error)
        {
            int code = error.HResult & 0xffff;
            return code == 32 || code == 33;
        }

        private void IoFailure(string message, bool transient)
        {
            lastIoError = "Bridge write failed: " + message;
            connection.Text = lastIoError;
            connection.ForeColor = Color.Salmon;
            readout.Text = "Waiting for control delivery. The runtime heartbeat expires after 3 seconds.";
            if (ioFailureSince == 0) ioFailureSince = Epoch();
            if (!transient || Epoch() - ioFailureSince > 3) Disarm();
        }

        private void FindGame()
        {
            gamePid = 0;
            foreach (Process process in Process.GetProcessesByName("SparkingZERO-Win64-Shipping"))
            {
                using (process)
                {
                    try
                    {
                        if (String.Equals(process.MainModule.FileName, executable, StringComparison.OrdinalIgnoreCase))
                        {
                            gamePid = (uint)process.Id;
                            return;
                        }
                    }
                    catch (System.ComponentModel.Win32Exception error)
                    {
                        connection.Text = "Cannot inspect the game process: " + error.Message;
                    }
                    catch (InvalidOperationException) { /* Process exited during enumeration. */ }
                }
            }
        }

        private void Poll(object sender, EventArgs args)
        {
            if (polls++ % 4 == 0) FindGame();
            Publish();
            if (lastIoError.Length != 0) return;
            string path = Path.Combine(bridge, "status.txt");
            if (!File.Exists(path))
            {
                LostResponse("Waiting for UE4SS. Launch the game normally.\nNo runtime handshake has been received.");
                return;
            }
            Dictionary<string, string> values = new Dictionary<string, string>();
            try
            {
                using (FileStream input = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
                using (StreamReader reader = new StreamReader(input))
                {
                    if (input.Length > 32768) throw new InvalidDataException("Runtime status is too large.");
                    string line;
                    while ((line = reader.ReadLine()) != null)
                    {
                        int equal = line.IndexOf('=');
                        if (equal > 0) values[line.Substring(0, equal)] = line.Substring(equal + 1);
                    }
                }
            }
            catch (IOException error)
            {
                LostResponse("Cannot read runtime status: " + error.Message);
                return;
            }
            catch (UnauthorizedAccessException error)
            {
                LostResponse("Runtime status access denied: " + error.Message);
                return;
            }
            if (Get(values, "complete") != "1")
            {
                LostResponse("Waiting for a complete runtime status.");
                return;
            }
            string status = Get(values, "state");
            if (status == "error")
            {
                Disarm();
                connection.Text = "Runtime stopped: " + Get(values, "message");
                connection.ForeColor = Color.Salmon;
                readout.Text = "Restart the game after resolving the UE4SS log error.";
                return;
            }
            long heartbeat;
            if (Get(values, "protocol") != "1" || !Int64.TryParse(Get(values, "heartbeat"), out heartbeat)
                || Epoch() - heartbeat > 3 || heartbeat - Epoch() > 1 || gamePid == 0)
            {
                Disarm();
                connection.Text = "Runtime not responding or game is closed.\nControls disarmed. Check ue4ss\\UE4SS.log.";
                connection.ForeColor = Color.Salmon;
                readout.Text = "No current runtime acknowledgement.";
                return;
            }
            string currentRuntime = Get(values, "runtime");
            if (runtime.Length > 0 && runtime != currentRuntime)
            {
                Disarm();
                Publish();
            }
            runtime = currentRuntime;
            lastRuntimeResponse = Epoch();
            if (Get(values, "session") != session || Get(values, "sequence") != sequence.ToString(CultureInfo.InvariantCulture))
            {
                connection.Text = "Connected. Waiting for the runtime to acknowledge changes.";
                connection.ForeColor = Color.Silver;
                return;
            }
            connection.Text = Get(values, "message");
            connection.ForeColor = status == "active" ? Color.LightGreen : status == "blocked" ? Color.Salmon : Color.Silver;
            readout.Text = status == "active"
                ? "HP " + Get(values, "health") + "  |  KI " + Get(values, "ki") + "  |  SKILL " + Get(values, "skill")
                    + "\nSPARKING " + Get(values, "sparking") + "  |  FPS CAP " + Get(values, "fps")
                : "No gameplay controls applied.";
        }

        private void LostResponse(string message)
        {
            connection.Text = message;
            connection.ForeColor = Color.Silver;
            if (Epoch() - lastRuntimeResponse > 3)
            {
                Disarm();
                Publish();
                connection.Text += "\nControls disarmed: no current acknowledgement.";
                connection.ForeColor = Color.Salmon;
                readout.Text = "No current runtime acknowledgement.";
            }
        }

        private static string Get(Dictionary<string, string> values, string key)
        {
            string value;
            return values.TryGetValue(key, out value) ? value : "";
        }

        private void ShowPanel()
        {
            Show();
            WindowState = FormWindowState.Normal;
            Activate();
        }

        protected override void WndProc(ref Message message)
        {
            if (message.Msg == 0x0312 && message.WParam.ToInt32() == 1)
            {
                uint foreground;
                GetWindowThreadProcessId(GetForegroundWindow(), out foreground);
                if (foreground == gamePid || foreground == (uint)Process.GetCurrentProcess().Id)
                {
                    if (Visible) Hide(); else ShowPanel();
                }
            }
            base.WndProc(ref message);
        }

        [STAThread]
        public static void Run(string modDirectory, string gameExecutable)
        {
            Application.EnableVisualStyles();
            try { Application.Run(new ModMenu(modDirectory, gameExecutable)); }
            catch (IOException error)
            {
                MessageBox.Show("Cannot open the control panel. Another panel may already be using this installation.\n\n" + error.Message,
                    "Dez's Minion", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
            catch (UnauthorizedAccessException error)
            {
                MessageBox.Show("The mod bridge directory must be writable by your Windows account.\n\n" + error.Message,
                    "Dez's Minion", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }
    }
}
