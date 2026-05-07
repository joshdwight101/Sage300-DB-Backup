using System.Data.SqlClient;
using System.Diagnostics;
using System.Text.Json;
using System.Windows.Forms;

internal static class Program
{
    const string AppTitle = "Sage 300 DB Backup Utility";
    const string Version = "v1.1.0";
    const string Author = "Joshua Dwight";
    static readonly string SettingsPath = Path.Combine(AppContext.BaseDirectory, "Sage300DBBackupUtility.settings.json");
    static AppSettings settings = Load();
    static Process? currentProcess; static bool cancel; static bool running;

    [STAThread] static void Main() { ApplicationConfiguration.Initialize(); Application.Run(BuildForm()); }

    static Form BuildForm() {
      var form=new Form{Text=$"{AppTitle} {Version}  |  Author: {Author}",Size=new(980,720),StartPosition=FormStartPosition.CenterScreen,Font=new("Segoe UI",10)};
      var txtServer=new TextBox{Location=new(140,46),Size=new(280,28),Text=settings.SqlServer}; var chkIntegrated=new CheckBox{Text="Use Windows Authentication",Location=new(440,48),Checked=settings.UseIntegratedSecurity,AutoSize=true};
      var txtSqlUser=new TextBox{Location=new(140,80),Size=new(200,28),Text=settings.SqlUser}; var txtSqlPass=new TextBox{Location=new(480,80),Size=new(220,28),Text=settings.SqlPassword,UseSystemPasswordChar=true};
      var txtRuntime=new TextBox{Location=new(140,116),Size=new(560,28),Text=settings.RuntimePath}; var txtBackupRoot=new TextBox{Location=new(140,151),Size=new(560,28),Text=settings.BackupRoot};
      var btnBrowseRuntime=new Button{Text="Browse...",Location=new(720,118),Size=new(120,36)}; var btnBrowseBackup=new Button{Text="Browse...",Location=new(720,160),Size=new(120,36)};
      var btnDetect=new Button{Text="Detect Databases",Location=new(720,76),Size=new(120,36)}; var listDb=new CheckedListBox{Location=new(20,205),Size=new(940,200),CheckOnClick=true};
      var txtSageUser=new TextBox{Location=new(160,420),Size=new(180,28),Text=settings.SageAdminUser}; var txtSagePass=new TextBox{Location=new(530,420),Size=new(220,28),Text=settings.SageAdminPassword,UseSystemPasswordChar=true};
      var btnStart=new Button{Text="Start Backup",Location=new(760,418),Size=new(180,34)}; var progress=new ProgressBar{Location=new(20,465),Size=new(940,24)}; var eta=new Label{Text="Estimated time remaining: --:--:--",Location=new(20,495),AutoSize=true};
      var log=new TextBox{Location=new(20,525),Size=new(940,150),Multiline=true,ScrollBars=ScrollBars.Vertical,ReadOnly=true};
      form.Controls.AddRange(new Control[]{new Label{Text="SQL Server:",Location=new(20,50),AutoSize=true},txtServer,chkIntegrated,new Label{Text="SQL User:",Location=new(20,85),AutoSize=true},txtSqlUser,new Label{Text="SQL Password:",Location=new(360,85),AutoSize=true},txtSqlPass,new Label{Text="Sage Runtime Path:",Location=new(20,120),AutoSize=true},txtRuntime,btnBrowseRuntime,new Label{Text="Backup Root:",Location=new(20,155),AutoSize=true},txtBackupRoot,btnBrowseBackup,btnDetect,listDb,new Label{Text="Sage Admin User:",Location=new(20,425),AutoSize=true},txtSageUser,new Label{Text="Sage Admin Password:",Location=new(360,425),AutoSize=true},txtSagePass,btnStart,progress,eta,log});
      void save(){settings=settings with{SqlServer=txtServer.Text,UseIntegratedSecurity=chkIntegrated.Checked,SqlUser=txtSqlUser.Text,SqlPassword=txtSqlPass.Text,RuntimePath=txtRuntime.Text,BackupRoot=txtBackupRoot.Text,SageAdminUser=txtSageUser.Text,SageAdminPassword=txtSagePass.Text}; File.WriteAllText(SettingsPath,JsonSerializer.Serialize(settings,new JsonSerializerOptions{WriteIndented=true}));}
      foreach(var c in new Control[]{txtServer,txtSqlUser,txtSqlPass,txtRuntime,txtBackupRoot,txtSageUser,txtSagePass}) c.TextChanged += (_,_)=>save(); chkIntegrated.CheckedChanged += (_,_)=>{txtSqlUser.Enabled=txtSqlPass.Enabled=!chkIntegrated.Checked; save();};
      btnDetect.Click += async (_,_)=>{try{listDb.Items.Clear(); Log(log,"Detecting Sage candidate databases..."); foreach(var db in await Task.Run(()=>Detect(txtServer.Text,chkIntegrated.Checked,txtSqlUser.Text,txtSqlPass.Text))) listDb.Items.Add(db,true);}catch(Exception ex){MessageBox.Show(ex.Message,"Detection failed");}};
      btnStart.Click += async (_,_)=>{ if(!running){ if(listDb.CheckedItems.Count==0){MessageBox.Show("Select at least one database to backup.");return;} running=true; cancel=false; btnStart.Text="Stop Backup"; var dbs=listDb.CheckedItems.Cast<object>().Select(x=>x.ToString()!).ToList(); try{await Backup(txtRuntime.Text,txtBackupRoot.Text,dbs,txtSageUser.Text,txtSagePass.Text,log,progress,eta); MessageBox.Show(cancel?"Backup cancelled.":"Backup completed successfully.");}catch(Exception ex){MessageBox.Show(ex.Message,"Backup failed");} finally{running=false; btnStart.Text="Start Backup";}} else {cancel=true; if(currentProcess is {HasExited:false} p) try{p.Kill();}catch{} }};
      btnBrowseRuntime.Click += (_,_)=>Browse(txtRuntime); btnBrowseBackup.Click += (_,_)=>Browse(txtBackupRoot);
      return form;
    }

    static async Task Backup(string runtime,string root,List<string> dbs,string user,string pass,TextBox log,ProgressBar prog,Label eta){var exe=Path.Combine(runtime,"dbdump32.exe"); if(!File.Exists(exe)) throw new Exception($"dbdump32.exe not found at {exe}"); var run=Path.Combine(root,DateTime.Now.ToString("yyyy-MM-dd")); Directory.CreateDirectory(run); var durs=new List<double>(); for(int i=0;i<dbs.Count;i++){ if(cancel) break; var db=dbs[i]; var dir=Path.Combine(run,$"{db}_backup_{DateTime.Now:yyyy-MM-dd_hh-mm-ss_tt}"); Directory.CreateDirectory(dir); Log(log,$"Starting backup for {db}"); var sw=Stopwatch.StartNew(); var psi=new ProcessStartInfo(exe){WorkingDirectory=runtime,UseShellExecute=false,CreateNoWindow=true}; psi.ArgumentList.Add($"/U{user}"); psi.ArgumentList.Add($"/P{pass}"); psi.ArgumentList.Add($"/L{db}"); psi.ArgumentList.Add("/Q"); psi.ArgumentList.Add($"/D{dir}"); currentProcess=Process.Start(psi)!; while(!currentProcess.HasExited){ if(cancel){try{currentProcess.Kill();}catch{} break;} await Task.Delay(250); Application.DoEvents(); } sw.Stop(); if(cancel) break; if(currentProcess.ExitCode!=0) throw new Exception($"dbdump32.exe failed for {db}"); durs.Add(sw.Elapsed.TotalSeconds); prog.Value=Math.Min((int)Math.Round(((i+1d)/dbs.Count)*100),100); eta.Text=$"Estimated time remaining: {TimeSpan.FromSeconds(Math.Round(durs.Average()*(dbs.Count-i-1))):hh\\:mm\\:ss}"; Log(log,$"Completed backup for {db}"); } eta.Text="Estimated time remaining: 00:00:00"; }
    static List<string> Detect(string server,bool integrated,string user,string pass){var cs=integrated?$"Server={server};Database=master;Integrated Security=True;TrustServerCertificate=True":$"Server={server};Database=master;User ID={user};Password={pass};TrustServerCertificate=True"; var q="SELECT name FROM sys.databases WHERE state_desc = 'ONLINE' AND name NOT IN ('master','model','msdb','tempdb') AND (name LIKE '%DAT' OR name LIKE '%SYS') ORDER BY name;"; var r=new List<string>(); using var c=new SqlConnection(cs); c.Open(); using var cmd=c.CreateCommand(); cmd.CommandText=q; using var rd=cmd.ExecuteReader(); while(rd.Read()) r.Add((string)rd["name"]); return r;}
    static void Log(TextBox b,string m){b.AppendText($"[{DateTime.Now:yyyy-MM-dd HH:mm:ss}] {m}{Environment.NewLine}"); b.SelectionStart=b.TextLength; b.ScrollToCaret();}
    static void Browse(TextBox t){using var d=new FolderBrowserDialog{ShowNewFolderButton=true}; if(Directory.Exists(t.Text)) d.SelectedPath=t.Text; if(d.ShowDialog()==DialogResult.OK) t.Text=d.SelectedPath;}
    static AppSettings Load(){try{if(File.Exists(SettingsPath)) return JsonSerializer.Deserialize<AppSettings>(File.ReadAllText(SettingsPath))??AppSettings.Default();}catch{} return AppSettings.Default();}
    record AppSettings(string SqlServer,bool UseIntegratedSecurity,string SqlUser,string SqlPassword,string RuntimePath,string BackupRoot,string SageAdminUser,string SageAdminPassword){public static AppSettings Default()=>new("localhost",true,"","",@"C:\Sage300\runtime",@"C:\Sage300\dbdump","ADMIN","");}
}
