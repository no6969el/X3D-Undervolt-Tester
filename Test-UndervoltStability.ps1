<#
==============================================================================
 Test-UndervoltStability.ps1   v4  -- "X3D CO Killer"  (interactive menu)
------------------------------------------------------------------------------
 Single-core stress + CORRECTNESS-VERIFICATION tester for hunting unstable
 Curve Optimizer / negative-offset undervolts on AMD Ryzen (X3D-focused).

 NEW IN v4
   * Interactive MENU -- pick cores, mode, and duration by number. No more
     fighting -Cores array parsing on the command line.
   * REMEMBERS FAILURES. On launch it reads the last run's results; if any core
     failed it offers to retest exactly those cores (pre-selected) with the
     profile(s) that failed. Answer Y to start immediately, or N to open the
     menu with those cores already selected.

 Just double-click a launcher or run:
     pwsh -File .\Test-UndervoltStability.ps1
 and follow the menu. Command-line switches still work and skip the menu.

 REQUIRES PowerShell 7.4+ (pwsh.exe) for AVX-512.
 See README.md for full documentation.
==============================================================================
#>

param(
    [ValidateSet('Quick','Standard','Thorough','Overnight','Extreme')]
    [string] $Preset,
    [int]    $SecondsPerCore,
    [int]    $Cycles,
    [ValidateSet('All','Boost','Mid','Heavy','Transient')]
    [string] $Mode,
    [int]    $ThreadsPerCore = 1,
    [switch] $IncludeMid,
    [int]    $TransientOnMs  = 3,
    [int]    $TransientOffMs = 3,
    [switch] $TransientSweep,
    [int[]]  $Cores,
    [switch] $Shuffle,
    [switch] $StopOnError,
    [switch] $NoClocks,
    [switch] $NoAvx512,
    [switch] $NoMenu,
    [string] $LogPath,
    [string] $ReportPath,

    # ---- worker parameters (script relaunches itself for per-core pinning) ----
    [switch] $WorkerMode,
    [string] $KernelClass = 'UvScalar',
    [ValidateSet('sustained','transient')]
    [string] $Pattern = 'sustained',
    [long]   $Affinity   = 0,
    [int]    $ThreadCount = 1,
    [int]    $BlockIters  = 0,
    [int]    $Duration    = 0,
    [int]    $OnMs        = 3,
    [int]    $OffMs       = 3,
    [switch] $Sweep,
    [string] $Heartbeat  = "",
    [string] $ResultFile = ""
)

$classTemplate = @'
public static class __CLASS__
{
    [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
    [DllImport("kernel32.dll")] static extern bool   SetProcessAffinityMask(IntPtr h, IntPtr mask);
    [DllImport("kernel32.dll")] static extern uint   SetThreadExecutionState(uint f);
    [DllImport("winmm.dll")]    static extern uint   timeBeginPeriod(uint p);
    [DllImport("winmm.dll")]    static extern uint   timeEndPeriod(uint p);

    public static void SetAffinity(long mask) { SetProcessAffinityMask(GetCurrentProcess(), (IntPtr)mask); }
    public static void KeepAwake(bool on) { uint C=0x80000000,S=0x00000001; SetThreadExecutionState(on?(C|S):C); }
    public static void HiRes(bool on) { try { if (on) timeBeginPeriod(1); else timeEndPeriod(1); } catch {} }

    public static ulong Block(int iters)
    {
//__BLOCK__
    }

    public static volatile bool Stop;
    public static long  Blocks;
    public static int   ErrorBlock = -1;
    public static ulong ErrGot, ErrWant, RefHash;

    // Derive a reference hash on THIS core; 3-way disagreement means it's
    // already so unstable it can't compute consistently -> instant fail.
    static bool ComputeRef(int iters)
    {
        ulong x = Block(iters), y = Block(iters), z = Block(iters);
        if (x == y || x == z) { RefHash = x; return true; }
        if (y == z)           { RefHash = y; return true; }
        RefHash = x; return false;
    }

    // Sustained load on 'threads' threads.
    public static int Run(int threads, int iters, int durationSec, string hbPath)
    {
        Stop=false; Blocks=0; ErrorBlock=-1;
        if (!ComputeRef(iters)) { ErrorBlock=-2; return -2; }
        ulong golden = RefHash;
        var sw = Stopwatch.StartNew();
        var ts = new Thread[threads];
        for (int t=0;t<threads;t++){
            ts[t]=new Thread(()=>{
                while(!Stop){
                    ulong h=Block(iters);
                    long b=Interlocked.Increment(ref Blocks);
                    if(h!=golden){ErrGot=h;ErrWant=golden;ErrorBlock=(int)b;Stop=true;break;}
                    if(sw.Elapsed.TotalSeconds>=durationSec){Stop=true;break;}
                }
            });
            ts[t].IsBackground=true;
        }
        foreach(var th in ts) th.Start();
        while(!Stop){ try{System.IO.File.WriteAllText(hbPath, sw.Elapsed.Ticks+" "+Interlocked.Read(ref Blocks));}catch{}
                      if(sw.Elapsed.TotalSeconds>=durationSec)Stop=true; Thread.Sleep(200); }
        foreach(var th in ts) th.Join(5000);
        try{System.IO.File.WriteAllText(hbPath, sw.Elapsed.Ticks+" "+Blocks);}catch{}
        return ErrorBlock;
    }

    // di/dt transient: all threads toggle load ON/OFF in phase (shared clock),
    // producing large synchronized current steps. Optional period sweep hits a
    // range of VRM response frequencies.
    public static int RunTransient(int threads, int iters, int durationSec, int onMs, int offMs, bool sweep, string hbPath)
    {
        Stop=false; Blocks=0; ErrorBlock=-1;
        if (!ComputeRef(iters)) { ErrorBlock=-2; return -2; }
        ulong golden = RefHash;
        HiRes(true);
        var sw = Stopwatch.StartNew();
        var ts = new Thread[threads];
        for (int t=0;t<threads;t++){
            ts[t]=new Thread(()=>{
                while(!Stop){
                    long ms = sw.ElapsedMilliseconds;
                    int on=onMs, off=offMs;
                    if(sweep){ int step=(int)((ms/500)%16); on=2+step; off=2+step; }
                    int period = on+off; if(period<2) period=2;
                    bool active = (ms % period) < on;
                    if(active){
                        ulong h=Block(iters);
                        long b=Interlocked.Increment(ref Blocks);
                        if(h!=golden){ErrGot=h;ErrWant=golden;ErrorBlock=(int)b;Stop=true;break;}
                    } else {
                        Thread.Sleep(1);
                    }
                    if(sw.Elapsed.TotalSeconds>=durationSec){Stop=true;break;}
                }
            });
            ts[t].IsBackground=true;
        }
        foreach(var th in ts) th.Start();
        while(!Stop){ try{System.IO.File.WriteAllText(hbPath, sw.Elapsed.Ticks+" "+Interlocked.Read(ref Blocks));}catch{}
                      if(sw.Elapsed.TotalSeconds>=durationSec)Stop=true; Thread.Sleep(100); }
        foreach(var th in ts) th.Join(5000);
        HiRes(false);
        try{System.IO.File.WriteAllText(hbPath, sw.Elapsed.Ticks+" "+Blocks);}catch{}
        return ErrorBlock;
    }
}
'@

$scalarBlock = @'
        double a0=1.0000001, a1=1.0000002, a2=1.0000003, a3=1.0000004;
        double a4=0.9999999, a5=0.9999998, a6=0.9999997, a7=0.9999996;
        double c=1.0000000007, d=0.0000000003;
        for (int i=0;i<iters;i++){
            a0=a0*c+d; a1=a1*c+d; a2=a2*c+d; a3=a3*c+d;
            a4=a4*c+d; a5=a5*c+d; a6=a6*c+d; a7=a7*c+d;
            if((i&1023)==0){ a0=Math.Sqrt(a0);a1=Math.Sqrt(a1);a2=Math.Sqrt(a2);a3=Math.Sqrt(a3);
                             a4=Math.Sqrt(a4);a5=Math.Sqrt(a5);a6=Math.Sqrt(a6);a7=Math.Sqrt(a7); }
        }
        double s=a0+a1+a2+a3+a4+a5+a6+a7;
        long bits=BitConverter.DoubleToInt64Bits(s);
        ulong h=1469598103934665603UL;
        for(int b=0;b<8;b++){ h^=(ulong)((bits>>(b*8))&0xff); h*=1099511628211UL; }
        return h;
'@

$simdBlock = @'
        int w=Vector<double>.Count;
        var a0=new Vector<double>(1.0000001); var a1=new Vector<double>(1.0000002);
        var a2=new Vector<double>(1.0000003); var a3=new Vector<double>(1.0000004);
        var a4=new Vector<double>(0.9999999); var a5=new Vector<double>(0.9999998);
        var a6=new Vector<double>(0.9999997); var a7=new Vector<double>(0.9999996);
        var c=new Vector<double>(1.0000000007); var d=new Vector<double>(0.0000000003);
        for(int i=0;i<iters;i++){
            a0=a0*c+d; a1=a1*c+d; a2=a2*c+d; a3=a3*c+d;
            a4=a4*c+d; a5=a5*c+d; a6=a6*c+d; a7=a7*c+d;
            if((i&1023)==0){ a0=Vector.SquareRoot(a0);a1=Vector.SquareRoot(a1);a2=Vector.SquareRoot(a2);a3=Vector.SquareRoot(a3);
                             a4=Vector.SquareRoot(a4);a5=Vector.SquareRoot(a5);a6=Vector.SquareRoot(a6);a7=Vector.SquareRoot(a7); }
        }
        var sum=a0+a1+a2+a3+a4+a5+a6+a7; double s=0.0; for(int k=0;k<w;k++) s+=sum[k];
        long bits=BitConverter.DoubleToInt64Bits(s);
        ulong h=1469598103934665603UL;
        for(int b=0;b<8;b++){ h^=(ulong)((bits>>(b*8))&0xff); h*=1099511628211UL; }
        return h;
'@

$avx512Block = @'
        var a0=Vector512.Create(1.0000001); var a1=Vector512.Create(1.0000002);
        var a2=Vector512.Create(1.0000003); var a3=Vector512.Create(1.0000004);
        var a4=Vector512.Create(0.9999999); var a5=Vector512.Create(0.9999998);
        var a6=Vector512.Create(0.9999997); var a7=Vector512.Create(0.9999996);
        var c=Vector512.Create(1.0000000007); var d=Vector512.Create(0.0000000003);
        for(int i=0;i<iters;i++){
            a0=Avx512F.Add(Avx512F.Multiply(a0,c),d); a1=Avx512F.Add(Avx512F.Multiply(a1,c),d);
            a2=Avx512F.Add(Avx512F.Multiply(a2,c),d); a3=Avx512F.Add(Avx512F.Multiply(a3,c),d);
            a4=Avx512F.Add(Avx512F.Multiply(a4,c),d); a5=Avx512F.Add(Avx512F.Multiply(a5,c),d);
            a6=Avx512F.Add(Avx512F.Multiply(a6,c),d); a7=Avx512F.Add(Avx512F.Multiply(a7,c),d);
            if((i&1023)==0){ a0=Avx512F.Sqrt(a0);a1=Avx512F.Sqrt(a1);a2=Avx512F.Sqrt(a2);a3=Avx512F.Sqrt(a3);
                             a4=Avx512F.Sqrt(a4);a5=Avx512F.Sqrt(a5);a6=Avx512F.Sqrt(a6);a7=Avx512F.Sqrt(a7); }
        }
        var sum=Avx512F.Add(Avx512F.Add(Avx512F.Add(a0,a1),Avx512F.Add(a2,a3)),
                            Avx512F.Add(Avx512F.Add(a4,a5),Avx512F.Add(a6,a7)));
        double s=0.0; for(int k=0;k<8;k++) s+=sum.GetElement(k);
        long bits=BitConverter.DoubleToInt64Bits(s);
        ulong h=1469598103934665603UL;
        for(int b=0;b<8;b++){ h^=(ulong)((bits>>(b*8))&0xff); h*=1099511628211UL; }
        return h;
'@

$usingsBase = "using System;`nusing System.Numerics;`nusing System.Diagnostics;`nusing System.Runtime.InteropServices;`nusing System.Threading;`n"
$usingsAvx  = $usingsBase + "using System.Runtime.Intrinsics;`nusing System.Runtime.Intrinsics.X86;`n"

$Kernels = @{}   # friendly name -> class name actually compiled

# scalar: always
Add-Type -TypeDefinition ($usingsBase + $classTemplate.Replace('__CLASS__','UvScalar').Replace('//__BLOCK__',$scalarBlock)) -ErrorAction Stop
$Kernels['scalar'] = 'UvScalar'

# simd (AVX2): if it compiles
try {
    $refs = @(); if ($PSVersionTable.PSEdition -eq 'Desktop') { try { $refs += [System.Numerics.Vector[double]].Assembly.Location } catch {} }
    $simdSrc = $usingsBase + $classTemplate.Replace('__CLASS__','UvSimd').Replace('//__BLOCK__',$simdBlock)
    if ($refs.Count -gt 0) { Add-Type -TypeDefinition $simdSrc -ReferencedAssemblies $refs -ErrorAction Stop }
    else                   { Add-Type -TypeDefinition $simdSrc -ErrorAction Stop }
    $Kernels['simd'] = 'UvSimd'
} catch {}

# avx-512: if CPU + runtime support it
$avx512ok = $false
if (-not $NoAvx512) { try { $avx512ok = [System.Runtime.Intrinsics.X86.Avx512F]::IsSupported } catch { $avx512ok = $false } }
if ($avx512ok) {
    try {
        Add-Type -TypeDefinition ($usingsAvx + $classTemplate.Replace('__CLASS__','UvAvx512').Replace('//__BLOCK__',$avx512Block)) -ErrorAction Stop
        $Kernels['avx512'] = 'UvAvx512'
    } catch {}
}

# best "wide" kernel available (max current for Heavy/Transient)
$wideKey  = if ($Kernels.ContainsKey('avx512')) { 'avx512' } elseif ($Kernels.ContainsKey('simd')) { 'simd' } else { 'scalar' }
$midKey   = if ($Kernels.ContainsKey('simd')) { 'simd' } else { 'scalar' }

# ===========================================================================
#  WORKER MODE
# ===========================================================================
if ($WorkerMode) {
    try {
        [UvScalar]::SetAffinity($Affinity)
        try { (Get-Process -Id $PID).PriorityClass = 'AboveNormal' } catch {}
        $T = [type]$KernelClass
        if ($Pattern -eq 'transient') {
            $fail = $T.GetMethod('RunTransient').Invoke($null, @([int]$ThreadCount,[int]$BlockIters,[int]$Duration,[int]$OnMs,[int]$OffMs,[bool]$Sweep,[string]$Heartbeat))
        } else {
            $fail = $T.GetMethod('Run').Invoke($null, @([int]$ThreadCount,[int]$BlockIters,[int]$Duration,[string]$Heartbeat))
        }
        $blocks = $T.GetField('Blocks').GetValue($null)
        $got    = $T.GetField('ErrGot').GetValue($null)
        $want   = $T.GetField('ErrWant').GetValue($null)
        if ($fail -eq -1)      { "OK $blocks"                                        | Set-Content $ResultFile -Encoding ASCII; exit 0 }
        elseif ($fail -eq -2)  { "REFFAIL could not compute a stable reference"      | Set-Content $ResultFile -Encoding ASCII; exit 2 }
        else                   { "ERROR block=$fail got=$got want=$want blocks=$blocks" | Set-Content $ResultFile -Encoding ASCII; exit 2 }
    } catch { "EXC $($_.Exception.Message)" | Set-Content $ResultFile -Encoding ASCII; exit 3 }
}

# ===========================================================================
#  ORCHESTRATOR MODE
# ===========================================================================
$ErrorActionPreference = 'Stop'
if (-not $PSCommandPath) { Write-Host "Save this to a .ps1 and run it from the file." -ForegroundColor Red; return }

$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$scriptDir = Split-Path $PSCommandPath -Parent
if (-not $LogPath)    { $LogPath    = Join-Path $scriptDir 'undervolt_test_log.txt' }
if (-not $ReportPath) { $ReportPath = Join-Path $scriptDir "undervolt_results_$stamp.csv" }
$hostExe = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
$script:showClocks = -not $NoClocks
$canKeys = $false; try { $null=[Console]::KeyAvailable; $canKeys=$true } catch { $canKeys=$false }

function Write-Log { param([string]$Text)
    try { $sw=[System.IO.StreamWriter]::new($LogPath,$true); $sw.WriteLine(("{0:yyyy-MM-dd HH:mm:ss}  {1}" -f (Get-Date),$Text)); $sw.Flush(); $sw.Close() } catch {}
}
function Format-HMS { param([double]$Seconds)
    if ($Seconds -lt 0){$Seconds=0}; $t=[TimeSpan]::FromSeconds([math]::Round($Seconds))
    '{0:00}:{1:00}:{2:00}' -f [int]$t.TotalHours,$t.Minutes,$t.Seconds
}
function Get-CoreClockMHz { param([int]$Lp)
    if (-not $script:showClocks){ return 0 }
    try { $c=Get-Counter -Counter "\Processor Information(0,$Lp)\% Processor Performance" -ErrorAction Stop
          return [int]($script:baseMHz * $c.CounterSamples[0].CookedValue / 100) } catch { $script:showClocks=$false; return 0 }
}

# ---- Topology ----
$cpu=Get-CimInstance Win32_Processor | Select-Object -First 1
$physCores=[int]$cpu.NumberOfCores; $logCores=[int]$cpu.NumberOfLogicalProcessors
$smtOn=($logCores -ge ($physCores*2)); $script:baseMHz=[int]$cpu.MaxClockSpeed
$coreMasks=@{}; $corePrimaryLp=@{}
for($i=0;$i -lt $physCores;$i++){
    if($smtOn){ $lo=2*$i; $corePrimaryLp[$i]=$lo
        $coreMasks[$i]=@{ one=([long]1 -shl $lo); both=(([long]1 -shl $lo) -bor ([long]1 -shl ($lo+1))) } }
    else { $corePrimaryLp[$i]=$i; $coreMasks[$i]=@{ one=([long]1 -shl $i); both=([long]1 -shl $i) } }
}
$dualCcd    = ($physCores -ge 12)
$ccdSize    = if($dualCcd){ [int]($physCores/2) } else { $physCores }
$allCores   = @(0..($physCores-1))

# ===========================================================================
#  PRIOR-RESULT MEMORY  -- find cores that failed the most recent run
# ===========================================================================
function Get-PreviousFailures {
    $out = [pscustomobject]@{ Cores=@(); Profiles=@(); When=$null; Source=$null; Crashed=$null }

    # 1) newest results CSV in the script folder
    try {
        $csv = Get-ChildItem -Path $scriptDir -Filter 'undervolt_results_*.csv' -ErrorAction Stop |
               Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($csv) {
            $rows = Import-Csv $csv.FullName
            $bad  = @($rows | Where-Object { ([int]$_.Fail -gt 0) -or ([int]$_.Whea -gt 0) } | ForEach-Object { [int]$_.Core })
            if ($bad.Count -gt 0) { $out.Cores = $bad; $out.When = $csv.LastWriteTime; $out.Source = $csv.Name }
        }
    } catch {}

    # 2) log gives us WHICH PROFILE failed, plus an unfinished (crash) core
    try {
        if (Test-Path $LogPath) {
            $lines = Get-Content $LogPath -Tail 4000
            $starts = @(); for($i=0;$i -lt $lines.Count;$i++){ if($lines[$i] -match '=== RUN START ==='){ $starts += $i } }
            $seg = if($starts.Count -gt 0){ $lines[$starts[-1]..($lines.Count-1)] } else { $lines }

            $profs = @(); $logCoresBad = @()
            foreach($l in $seg){
                if($l -match 'core (\d+) \[([A-Z]+)\] FAIL'){ $logCoresBad += [int]$matches[1]; $profs += $matches[2] }
                elseif($l -match 'core (\d+) \[([A-Z]+)\] WHEA'){ $logCoresBad += [int]$matches[1]; $profs += $matches[2] }
            }
            if($profs.Count -gt 0){ $out.Profiles = @($profs | Select-Object -Unique) }
            if($out.Cores.Count -eq 0 -and $logCoresBad.Count -gt 0){
                $out.Cores = @($logCoresBad | Select-Object -Unique | Sort-Object); $out.Source = 'log'
            }

            # unfinished core => prior hard lock / BSOD
            $suspect=$null; $idx=-1
            for($j=$seg.Count-1;$j -ge 0;$j--){ if($seg[$j] -match 'begin core (\d+)'){ $suspect=[int]$matches[1]; $idx=$j; break } }
            if($null -ne $suspect){
                $after = $seg[$idx..($seg.Count-1)]
                if(-not (($after -match ("core {0}\b.*(PASS|FAIL|WHEA|REF)" -f $suspect)) -or ($after -match 'RUN END'))){
                    $out.Crashed = $suspect
                }
            }
        }
    } catch {}

    $out.Cores = @($out.Cores | Select-Object -Unique | Sort-Object)
    return $out
}

# ===========================================================================
#  MENU HELPERS
# ===========================================================================
function Format-CoreList { param([int[]]$List)
    if(-not $List -or $List.Count -eq 0){ return '(none)' }
    if($List.Count -eq $physCores){ return "ALL ($physCores cores)" }
    return ($List -join ',')
}
function Read-Choice { param([string]$Prompt='Select')
    Write-Host ""
    Write-Host ("  {0}: " -f $Prompt) -NoNewline -ForegroundColor White
    return (Read-Host)
}
function Show-Header {
    Clear-Host
    Write-Host ""
    Write-Host "  ===============================================================" -ForegroundColor Cyan
    Write-Host "    X3D UNDERVOLT CO KILLER  v4        Curve Optimizer validator" -ForegroundColor Cyan
    Write-Host "  ===============================================================" -ForegroundColor Cyan
    Write-Host ("   {0}" -f $cpu.Name.Trim()) -ForegroundColor Gray
    Write-Host ("   {0} physical / {1} logical cores   |   kernels: {2}" -f $physCores,$logCores,(($Kernels.Keys|Sort-Object) -join ',')) -ForegroundColor DarkGray
    if($wideKey -ne 'avx512'){ Write-Host "   NOTE: AVX-512 inactive (needs PowerShell 7.4+ on an AVX-512 CPU)" -ForegroundColor Yellow }
    Write-Host ""
}

function Select-Cores { param([int[]]$Current,[int[]]$Failed)
    while($true){
        Show-Header
        Write-Host "   SELECT CORES TO TEST" -ForegroundColor White
        Write-Host "   --------------------" -ForegroundColor DarkGray
        Write-Host ("     current selection: {0}" -f (Format-CoreList $Current)) -ForegroundColor Green
        Write-Host ""
        Write-Host ("     1.  All cores  (0-{0})" -f ($physCores-1))
        if($Failed.Count -gt 0){
            Write-Host ("     2.  Previously FAILED cores  ({0})" -f ($Failed -join ',')) -ForegroundColor Yellow
        } else {
            Write-Host "     2.  Previously failed cores  (none on record)" -ForegroundColor DarkGray
        }
        Write-Host "     3.  Type specific cores"
        if($dualCcd){
            Write-Host ("     4.  CCD 0  (cores 0-{0})" -f ($ccdSize-1))
            Write-Host ("     5.  CCD 1  (cores {0}-{1})" -f $ccdSize,($physCores-1))
        }
        Write-Host "     0.  Back"
        $c = Read-Choice
        switch($c){
            '1' { return $allCores }
            '2' { if($Failed.Count -gt 0){ return $Failed } }
            '3' {
                Write-Host ""
                Write-Host "   Enter core numbers separated by commas or spaces (e.g. 6,15)" -ForegroundColor Gray
                $raw = Read-Host "   Cores"
                $parsed = @()
                foreach($tok in ($raw -split '[,\s]+')){
                    if($tok -match '^\d+$'){ $n=[int]$tok; if($n -ge 0 -and $n -lt $physCores){ $parsed += $n } }
                }
                $parsed = @($parsed | Select-Object -Unique | Sort-Object)
                if($parsed.Count -gt 0){ return $parsed }
                Write-Host "   No valid core numbers in that input." -ForegroundColor Red; Start-Sleep 2
            }
            '4' { if($dualCcd){ return @(0..($ccdSize-1)) } }
            '5' { if($dualCcd){ return @($ccdSize..($physCores-1)) } }
            '0' { return $Current }
        }
    }
}

function Select-Mode { param([string]$Current)
    while($true){
        Show-Header
        Write-Host "   SELECT TEST TYPE" -ForegroundColor White
        Write-Host "   ----------------" -ForegroundColor DarkGray
        Write-Host ("     current: {0}" -f $Current) -ForegroundColor Green
        Write-Host ""
        Write-Host "     1.  ALL        Boost + Transient + Heavy   (recommended)"
        Write-Host "     2.  BOOST      max clock / lowest voltage  (idle-crash corner)"
        Write-Host "     3.  TRANSIENT  di/dt load-step killer      (the nastiest)"
        Write-Host "     4.  HEAVY      sustained AVX-512, max current"
        Write-Host "     5.  MID        AVX2 mid-curve"
        Write-Host "     0.  Back"
        switch(Read-Choice){
            '1' { return 'All' } '2' { return 'Boost' } '3' { return 'Transient' }
            '4' { return 'Heavy' } '5' { return 'Mid' } '0' { return $Current }
        }
    }
}

function Select-Duration { param([string]$CurrentPreset)
    while($true){
        Show-Header
        Write-Host "   SELECT DURATION" -ForegroundColor White
        Write-Host "   ---------------" -ForegroundColor DarkGray
        Write-Host ("     current: {0}" -f $CurrentPreset) -ForegroundColor Green
        Write-Host ""
        Write-Host "     1.  Quick       90s per profile,  1 cycle"
        Write-Host "     2.  Standard   150s per profile,  1 cycle"
        Write-Host "     3.  Thorough   300s per profile,  2 cycles (shuffled)"
        Write-Host "     4.  Overnight  600s per profile,  6 cycles (shuffled)"
        Write-Host "     5.  Extreme    300s x3 cycles + AVX2 mid + sweep + 2-thread heavy"
        Write-Host "     6.  Custom seconds per profile"
        Write-Host "     0.  Back"
        switch(Read-Choice){
            '1' { return 'Quick' } '2' { return 'Standard' } '3' { return 'Thorough' }
            '4' { return 'Overnight' } '5' { return 'Extreme' }
            '6' {
                $s = Read-Host "   Seconds per profile"
                if($s -match '^\d+$' -and [int]$s -ge 10){ $script:customSeconds=[int]$s; return 'Custom' }
                Write-Host "   Enter a whole number >= 10." -ForegroundColor Red; Start-Sleep 2
            }
            '0' { return $CurrentPreset }
        }
    }
}

function Select-Advanced {
    while($true){
        Show-Header
        Write-Host "   ADVANCED OPTIONS" -ForegroundColor White
        Write-Host "   ----------------" -ForegroundColor DarkGray
        Write-Host ("     1.  Transient period sweep .... {0}" -f $(if($script:optSweep){'ON  (hits more VRM frequencies)'}else{'off'}))
        Write-Host ("     2.  Heavy threads per core .... {0}" -f $script:optThreads)
        Write-Host ("     3.  Shuffle core order ........ {0}" -f $(if($script:optShuffle){'ON'}else{'off'}))
        Write-Host ("     4.  Stop on first error ....... {0}" -f $(if($script:optStopOnError){'ON'}else{'off'}))
        Write-Host ("     5.  Include AVX2 MID profile .. {0}" -f $(if($script:optIncludeMid){'ON'}else{'off'}))
        Write-Host ("     6.  Cycles .................... {0}" -f $script:optCycles)
        Write-Host "     0.  Back"
        switch(Read-Choice){
            '1' { $script:optSweep = -not $script:optSweep }
            '2' { $script:optThreads = if($script:optThreads -ge 2){1}else{2} }
            '3' { $script:optShuffle = -not $script:optShuffle }
            '4' { $script:optStopOnError = -not $script:optStopOnError }
            '5' { $script:optIncludeMid = -not $script:optIncludeMid }
            '6' { $v = Read-Host "   Cycles (1-99)"; if($v -match '^\d+$' -and [int]$v -ge 1 -and [int]$v -le 99){ $script:optCycles=[int]$v } }
            '0' { return }
        }
    }
}

# ===========================================================================
#  MENU FLOW
# ===========================================================================
$explicitArgs = $PSBoundParameters.ContainsKey('Cores') -or $PSBoundParameters.ContainsKey('Mode') -or
                $PSBoundParameters.ContainsKey('Preset') -or $PSBoundParameters.ContainsKey('SecondsPerCore')
$interactive  = $canKeys -and -not $NoMenu -and -not $explicitArgs

# defaults that the menu edits
$script:optSweep       = [bool]$TransientSweep
$script:optThreads     = if($ThreadsPerCore -ge 2){2}else{1}
$script:optShuffle     = [bool]$Shuffle
$script:optStopOnError = [bool]$StopOnError
$script:optIncludeMid  = [bool]$IncludeMid
$script:optCycles      = if($PSBoundParameters.ContainsKey('Cycles')){$Cycles}else{1}
$script:customSeconds  = 0

$selCores  = if($Cores){ @($Cores|Where-Object{$coreMasks.ContainsKey($_)}) } else { $allCores }
$selMode   = if($Mode){ $Mode } else { 'All' }
$selPreset = if($Preset){ $Preset } else { 'Standard' }

if($interactive){
    $prev = Get-PreviousFailures

    # --- suggestion screen: retest previously failed cores? ---
    if($prev.Cores.Count -gt 0 -or $null -ne $prev.Crashed){
        Show-Header
        Write-Host "   PREVIOUS RESULTS FOUND" -ForegroundColor Yellow
        Write-Host "   ----------------------" -ForegroundColor DarkGray
        if($prev.When){ Write-Host ("   Last run: {0:yyyy-MM-dd HH:mm}" -f $prev.When) -ForegroundColor DarkGray }
        Write-Host ""
        if($prev.Cores.Count -gt 0){
            Write-Host ("   These cores FAILED:  {0}" -f ($prev.Cores -join ', ')) -ForegroundColor Red
            if($prev.Profiles.Count -gt 0){ Write-Host ("   Failing profile(s):  {0}" -f ($prev.Profiles -join ', ')) -ForegroundColor Red }
        }
        if($null -ne $prev.Crashed){
            Write-Host ("   A previous run stopped on Core {0} with no result recorded." -f $prev.Crashed) -ForegroundColor Magenta
            Write-Host "   If that was a hard lock/BSOD, that core is a prime suspect." -ForegroundColor Magenta
        }
        $suggestCores = @($prev.Cores); if($null -ne $prev.Crashed -and $suggestCores -notcontains $prev.Crashed){ $suggestCores += $prev.Crashed }
        $suggestCores = @($suggestCores | Sort-Object)
        $suggestMode  = if($prev.Profiles.Count -eq 1){ switch($prev.Profiles[0]){ 'BOOST'{'Boost'} 'TRANSIENT'{'Transient'} 'HEAVY'{'Heavy'} 'MID'{'Mid'} default{'All'} } } else { 'All' }

        Write-Host ""
        Write-Host "   SUGGESTED RETEST" -ForegroundColor Green
        Write-Host ("     Cores : {0}" -f ($suggestCores -join ',')) -ForegroundColor Green
        Write-Host ("     Test  : {0}" -f $suggestMode) -ForegroundColor Green
        Write-Host  "     Length: Thorough (300s per profile, 2 cycles, shuffled)" -ForegroundColor Green
        Write-Host ""
        Write-Host "   (Raise the Curve Optimizer offset on those cores in BIOS first!)" -ForegroundColor DarkYellow
        Write-Host ""
        Write-Host "   Run this retest now?  [Y] yes, start    [N] no, open the menu" -ForegroundColor White
        $ans = Read-Host "   Choice"
        if($ans -match '^(y|yes|)$'){
            $selCores=$suggestCores; $selMode=$suggestMode; $selPreset='Thorough'
            $script:optSweep=$true; $interactive=$false   # skip straight to the run
        } else {
            $selCores=$suggestCores; $selMode=$suggestMode   # pre-select, then show menu
        }
    }
}

if($interactive){
    $go=$false
    while(-not $go){
        Show-Header
        $secPreview = switch($selPreset){ 'Quick'{90} 'Standard'{150} 'Thorough'{300} 'Overnight'{600} 'Extreme'{300} 'Custom'{$script:customSeconds} default{150} }
        $cycPreview = switch($selPreset){ 'Thorough'{2} 'Overnight'{6} 'Extreme'{3} default{$script:optCycles} }
        $profCount  = switch($selMode){ 'All'{ if($script:optIncludeMid -or $selPreset -eq 'Extreme'){4}else{3} } default{1} }
        $estSecMenu = $selCores.Count * $cycPreview * $profCount * ($secPreview+2)

        Write-Host "   MAIN MENU" -ForegroundColor White
        Write-Host "   ---------" -ForegroundColor DarkGray
        Write-Host ("     1.  Cores ...... {0}" -f (Format-CoreList $selCores)) -ForegroundColor Gray
        Write-Host ("     2.  Test type .. {0}" -f $selMode) -ForegroundColor Gray
        Write-Host ("     3.  Duration ... {0}  ({1}s per profile, {2} cycle(s))" -f $selPreset,$secPreview,$cycPreview) -ForegroundColor Gray
        Write-Host  "     4.  Advanced options" -ForegroundColor Gray
        Write-Host ""
        Write-Host ("        estimated run time: ~{0}   (ETA {1:HH:mm})" -f (Format-HMS $estSecMenu),((Get-Date).AddSeconds($estSecMenu))) -ForegroundColor DarkGray
        Write-Host ""
        Write-Host "     5.  START TEST" -ForegroundColor Green
        Write-Host "     0.  Exit" -ForegroundColor DarkGray
        switch(Read-Choice){
            '1' { $prev2 = Get-PreviousFailures; $selCores = Select-Cores -Current $selCores -Failed $prev2.Cores }
            '2' { $selMode = Select-Mode -Current $selMode }
            '3' { $selPreset = Select-Duration -CurrentPreset $selPreset }
            '4' { Select-Advanced }
            '5' { if($selCores.Count -gt 0){ $go=$true } else { Write-Host "   Select at least one core first." -ForegroundColor Red; Start-Sleep 2 } }
            '0' { Write-Host ""; return }
        }
    }
    Clear-Host
}

# ---- Resolve menu choices into the run configuration ----
$Cores = $selCores; $Mode = $selMode
switch($selPreset){
    'Quick'     { $d=@{SecondsPerCore=90; Cycles=1} }
    'Standard'  { $d=@{SecondsPerCore=150;Cycles=1} }
    'Thorough'  { $d=@{SecondsPerCore=300;Cycles=2}; $script:optShuffle=$true }
    'Overnight' { $d=@{SecondsPerCore=600;Cycles=6}; $script:optShuffle=$true }
    'Extreme'   { $d=@{SecondsPerCore=300;Cycles=3}; $script:optShuffle=$true; $script:optIncludeMid=$true; $script:optSweep=$true; $script:optThreads=2 }
    'Custom'    { $d=@{SecondsPerCore=$script:customSeconds;Cycles=$script:optCycles} }
    default     { $d=@{SecondsPerCore=150;Cycles=1} }
}
if (-not $PSBoundParameters.ContainsKey('SecondsPerCore')) { $SecondsPerCore = $d.SecondsPerCore }
if (-not $PSBoundParameters.ContainsKey('Cycles'))         { $Cycles         = if($selPreset -in 'Custom'){$script:optCycles}else{$d.Cycles} }
if ($Preset -eq 'Extreme') { $script:optIncludeMid=$true; $script:optSweep=$true; if(-not $PSBoundParameters.ContainsKey('ThreadsPerCore')){ $script:optThreads=2 } }

$TransientSweep = [switch]$script:optSweep
$Shuffle        = [switch]$script:optShuffle
$StopOnError    = [switch]$script:optStopOnError
$IncludeMid     = [switch]$script:optIncludeMid
$ThreadsPerCore = $script:optThreads

$heavyThreads = if($smtOn){[math]::Min($ThreadsPerCore,2)}else{1}
$coreList = @($Cores|Where-Object{$coreMasks.ContainsKey($_)})
if(-not $coreList -or $coreList.Count -eq 0){ Write-Host "No valid cores selected." -ForegroundColor Red; return }

# ---- Calibrate iters-per-block for each compiled kernel ----
function Get-Iters { param([string]$ClassName,[double]$TargetMs)
    $T=[type]$ClassName
    $probe=200000
    $t=Measure-Command { [void]$T.GetMethod('Block').Invoke($null,@([int]$probe)) }
    $per=$t.TotalSeconds/$probe
    [int][math]::Max(1000,[math]::Round(($TargetMs/1000.0)/[math]::Max($per,1e-12)))
}

# ---- Build the profile plan ----
$profiles = @()
function Add-Profile { param($Name,$KernelKey,$Pattern,$Threads,$MaskKey,$TargetMs)
    $cls=$Kernels[$KernelKey]
    $script:profiles += [pscustomobject]@{
        Name=$Name; Kernel=$cls; Pattern=$Pattern; Threads=$Threads; MaskKey=$MaskKey
        BlockIters=(Get-Iters -ClassName $cls -TargetMs $TargetMs)
        OnMs=$TransientOnMs; OffMs=$TransientOffMs; Sweep=[bool]$TransientSweep
    }
}
$wantBoost     = ($Mode -in 'All','Boost')
$wantMid       = ($Mode -eq 'Mid') -or ($Mode -eq 'All' -and $IncludeMid)
$wantTransient = ($Mode -in 'All','Transient')
$wantHeavy     = ($Mode -in 'All','Heavy')

if ($wantBoost)     { Add-Profile 'BOOST'     'scalar'  'sustained' 1                       'one'  100 }
if ($wantMid)       { Add-Profile 'MID'       $midKey   'sustained' 1                       'one'  100 }
if ($wantTransient) { Add-Profile 'TRANSIENT' $wideKey  'transient' $(if($smtOn){2}else{1}) 'both' 0.4 }
if ($wantHeavy)     { Add-Profile 'HEAVY'     $wideKey  'sustained' $heavyThreads           $(if($heavyThreads -ge 2){'both'}else{'one'}) 100 }
if (-not $profiles) { Write-Host "No profiles selected for Mode '$Mode'." -ForegroundColor Red; return }

# ---- Banner ----
$vecName = switch ($wideKey) { 'avx512' {'AVX-512 512-bit'} 'simd' {'AVX2 256-bit'} default {'scalar'} }
Write-Host ""
Write-Host "  X3D Undervolt CO Killer  (v4)" -ForegroundColor Cyan
Write-Host "  =============================" -ForegroundColor Cyan
Write-Host ("  CPU        : {0}" -f $cpu.Name.Trim())
Write-Host ("  Cores      : testing {0} of {1}  ->  {2}" -f $coreList.Count,$physCores,(Format-CoreList $coreList)) -ForegroundColor White
Write-Host ("  Kernels    : {0}   (heavy/transient use {1})" -f (($Kernels.Keys|Sort-Object) -join ', '), $vecName)
Write-Host ("  PowerShell : {0} ({1})" -f $PSVersionTable.PSVersion,$PSVersionTable.PSEdition)
if ($wideKey -ne 'avx512' -and -not $NoAvx512) {
    Write-Host "               (AVX-512 not active: needs PowerShell 7.4+/.NET 8+ on an AVX-512 CPU.)" -ForegroundColor DarkGray
}
Write-Host  "  Profiles/core:"
foreach($p in $profiles){
    $extra = if($p.Pattern -eq 'transient'){ if($p.Sweep){"toggle sweep 2-17ms, $($p.Threads) threads"}else{"toggle $($p.OnMs)/$($p.OffMs)ms, $($p.Threads) threads"} } else { "$($p.Threads) thread(s)" }
    Write-Host ("     {0,-9} {1,-8} {2}" -f $p.Name,$p.Kernel,$extra) -ForegroundColor Gray
}
$subTotal = $coreList.Count * $Cycles * $profiles.Count
$estSec   = $subTotal * ($SecondsPerCore + 2)
Write-Host ("  Plan       : {0} core(s) x {1} cycle(s) x {2} profile(s) x {3}s = ~{4}  (ETA {5:HH:mm})" -f `
    $coreList.Count,$Cycles,$profiles.Count,$SecondsPerCore,(Format-HMS $estSec),((Get-Date).AddSeconds($estSec)))
Write-Host ("  Log        : {0}" -f $LogPath)
if($canKeys){ Write-Host "  Press Q to stop cleanly after the current profile." -ForegroundColor DarkGray }
Write-Host ""

[UvScalar]::KeepAwake($true)
Write-Log "=== RUN START === $($cpu.Name.Trim()) | wide=$vecName | mode=$Mode | cores=$($coreList -join ',') | $($coreList.Count)c x $Cycles cy x $($profiles.Count)prof x ${SecondsPerCore}s"

$results=@{}
foreach($c in $coreList){ $results[$c]=[pscustomobject]@{ Core=$c; Pass=0; Fail=0; Whea=0; PeakMHz=0; Status='pending'; Detail='' } }

$tmp=[System.IO.Path]::GetTempPath()
$script:runStart=Get-Date; $script:completedSubs=0; $script:currentProc=$null; $script:abort=$false

function Invoke-CoreProfile {
    param([int]$Core,[int]$Cycle,$Profile)
    $mask=$coreMasks[$Core][$Profile.MaskKey]; $primeLp=$corePrimaryLp[$Core]
    $hbFile=Join-Path $tmp ("uv_hb_{0}_{1}.txt" -f $Core,$Profile.Name)
    $resFile=Join-Path $tmp ("uv_res_{0}_{1}.txt" -f $Core,$Profile.Name)
    Remove-Item $hbFile,$resFile -ErrorAction SilentlyContinue

    $lpDesc = if($smtOn){ if($Profile.MaskKey -eq 'both'){"CPU$([int]2*$Core)+$([int](2*$Core+1))"}else{"CPU$([int]2*$Core)"} } else { "CPU$Core" }
    Write-Log ("CYCLE $Cycle : begin core $Core [$($Profile.Name)] ($lpDesc) mask=0x{0:X}" -f $mask)

    $wheaRef=Get-Date
    $argStr = @(
        '-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$PSCommandPath`"",'-WorkerMode',
        '-KernelClass',$Profile.Kernel,'-Pattern',$Profile.Pattern,'-Affinity',$mask,
        '-ThreadCount',$Profile.Threads,'-BlockIters',$Profile.BlockIters,'-Duration',$SecondsPerCore,
        '-OnMs',$Profile.OnMs,'-OffMs',$Profile.OffMs,
        $(if($Profile.Sweep){'-Sweep'}else{$null}),
        '-Heartbeat',"`"$hbFile`"",'-ResultFile',"`"$resFile`"",
        $(if($NoAvx512){'-NoAvx512'}else{$null})
    ) -join ' '
    $psi=New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName=$hostExe; $psi.Arguments=$argStr; $psi.UseShellExecute=$false; $psi.CreateNoWindow=$true
    $proc=[System.Diagnostics.Process]::Start($psi); $script:currentProc=$proc

    $coreStart=Get-Date; $peakMHz=0; $lastClock=Get-Date; $graceSec=25
    while($true){
        Start-Sleep -Milliseconds 250
        $elapsed=((Get-Date)-$coreStart).TotalSeconds; $remaining=$SecondsPerCore-$elapsed
        $blocks=0; $hbAge=999
        if(Test-Path $hbFile){ try{ $blocks=[int64]((Get-Content $hbFile -Raw).Trim().Split(' ')[1])
                                     $hbAge=((Get-Date)-[System.IO.File]::GetLastWriteTime($hbFile)).TotalSeconds }catch{} }
        if($script:showClocks -and ((Get-Date)-$lastClock).TotalSeconds -ge 2){
            $m=Get-CoreClockMHz -Lp $primeLp; $lastClock=Get-Date; if($m -gt $peakMHz){$peakMHz=$m} }
        $progUnits=$script:completedSubs+[math]::Min($elapsed/$SecondsPerCore,1)
        $ovElapsed=((Get-Date)-$script:runStart).TotalSeconds
        $ovLeft = if($progUnits -gt 0.05){ ($ovElapsed/$progUnits)*($subTotal-$progUnits) } else { ($subTotal-$progUnits)*$SecondsPerCore }
        $clk = if($peakMHz -gt 0){ ('~{0:0.00}GHz' -f ($peakMHz/1000)) } else { '--' }
        $flag = if($elapsed -gt 6 -and $hbAge -gt 15 -and -not $proc.HasExited){' [!! stalled]'}else{''}
        $line=("[C{0}/{1} S{2}/{3}] Core {4,2} {5,-9} | {6}/{7} | {8} pk | blk {9} | left {10}{11}" -f `
            $Cycle,$Cycles,($script:completedSubs+1),$subTotal,$Core,$Profile.Name,(Format-HMS $remaining),(Format-HMS $SecondsPerCore),$clk,$blocks,(Format-HMS $ovLeft),$flag)
        [Console]::Write("`r"+$line.PadRight(118).Substring(0,[math]::Min(118,$line.PadRight(118).Length)))
        if($canKeys -and [Console]::KeyAvailable){ if(([Console]::ReadKey($true)).Key -eq 'Q'){ $script:abort=$true } }
        if($proc.HasExited){ break }
        if($hbAge -gt 45 -and $elapsed -gt 6){ break }
        if($elapsed -gt ($SecondsPerCore+$graceSec)){ break }
        if($script:abort){ break }
    }
    [Console]::Write("`r"+(' '*118)+"`r")

    $outcome='pass'; $detail=''
    if(-not $proc.HasExited){ try{$proc.Kill();$proc.WaitForExit(3000)}catch{}
        if($script:abort){$outcome='aborted';$detail='stopped by user'} else {$outcome='hang';$detail='HANG / soft-lock (killed)'} }
    else {
        $res = if(Test-Path $resFile){(Get-Content $resFile -Raw).Trim()}else{"no-result (exit $($proc.ExitCode))"}
        if($res -like 'OK*'){$outcome='pass';$detail=$res}
        elseif($res -like 'REFFAIL*'){$outcome='miscalc';$detail='unstable from the start ('+$res+')'}
        elseif($res -like 'ERROR*'){$outcome='miscalc';$detail=$res}
        elseif($res -like 'EXC*'){$outcome='exc';$detail=$res}
        else{$outcome='hang';$detail=$res}
    }
    $wheaN=0; try{ $w=Get-WinEvent -FilterHashtable @{LogName='System';ProviderName='Microsoft-Windows-WHEA-Logger';StartTime=$wheaRef} -ErrorAction Stop; $wheaN=@($w).Count }catch{$wheaN=0}
    Remove-Item $hbFile,$resFile -ErrorAction SilentlyContinue; $script:currentProc=$null
    [pscustomobject]@{ Outcome=$outcome; Detail=$detail; Whea=$wheaN; PeakMHz=$peakMHz }
}

try {
    for($cycle=1;$cycle -le $Cycles -and -not $script:abort;$cycle++){
        $order=@($coreList); if($Shuffle){$order=@($order|Get-Random -Count $order.Count)}
        foreach($core in $order){
            if($script:abort){break}
            foreach($profile in $profiles){
                if($script:abort){break}
                $o=Invoke-CoreProfile -Core $core -Cycle $cycle -Profile $profile
                $r=$results[$core]; if($o.PeakMHz -gt $r.PeakMHz){$r.PeakMHz=$o.PeakMHz}
                switch($o.Outcome){
                    'pass' { $r.Pass++; if($r.Status -notin 'FAIL','WHEA'){$r.Status='pass'}
                        $pk=if($o.PeakMHz -gt 0){(' peak ~{0:0.00}GHz' -f ($o.PeakMHz/1000))}else{''}
                        Write-Host ("  Core {0,2} [{1,-9}] pass{2}" -f $core,$profile.Name,$pk) -ForegroundColor Green
                        Write-Log ("CYCLE $cycle : core $core [$($profile.Name)] PASS $($o.Detail)") }
                    'aborted' { Write-Host ("  Core {0,2} [{1,-9}] stopped" -f $core,$profile.Name) -ForegroundColor DarkGray }
                    default {
                        $r.Fail++; $r.Status='FAIL'; $r.Detail=$o.Detail
                        $lbl=switch($o.Outcome){'miscalc'{'FAIL - wrong result (unstable undervolt)'} 'hang'{'FAIL - hang / soft-lock'} 'exc'{'FAIL - worker exception'} default{'FAIL'}}
                        Write-Host ("  Core {0,2} [{1,-9}] {2}" -f $core,$profile.Name,$lbl) -ForegroundColor Red
                        Write-Host ("             {0}" -f $o.Detail) -ForegroundColor DarkRed
                        Write-Log ("CYCLE $cycle : core $core [$($profile.Name)] FAIL $($o.Detail)") }
                }
                if($o.Whea -gt 0){ $r.Whea+=$o.Whea; if($r.Status -ne 'FAIL'){$r.Status='WHEA'}
                    Write-Host ("             +{0} WHEA hardware error(s)!" -f $o.Whea) -ForegroundColor Yellow
                    Write-Log ("CYCLE $cycle : core $core [$($profile.Name)] WHEA x$($o.Whea)") }
                $script:completedSubs++
                if($StopOnError -and $o.Outcome -in 'miscalc','hang','exc'){ $script:abort=$true; Write-Host "  -StopOnError: halting." -ForegroundColor Yellow }
            }
        }
    }
}
finally {
    if($script:currentProc -and -not $script:currentProc.HasExited){ try{$script:currentProc.Kill()}catch{} }
    [UvScalar]::KeepAwake($false)
}

Write-Host ""
Write-Host "  ==============================  SUMMARY  ==============================" -ForegroundColor Cyan
$failed=@()
foreach($c in ($results.Keys|Sort-Object)){
    $r=$results[$c]
    $color=switch($r.Status){'pass'{'Green'}'FAIL'{'Red'}'WHEA'{'Yellow'}default{'Gray'}}
    $tag=switch($r.Status){'pass'{'PASS'}'FAIL'{'*** FAIL ***'}'WHEA'{'WHEA (calc ok)'}default{$r.Status}}
    $pk=if($r.PeakMHz -gt 0){('peak ~{0:0.00}GHz' -f ($r.PeakMHz/1000))}else{''}
    Write-Host ("  Core {0,2}: {1,-16} pass:{2} fail:{3} whea:{4}  {5}  {6}" -f $c,$tag,$r.Pass,$r.Fail,$r.Whea,$pk,$r.Detail) -ForegroundColor $color
    if($r.Status -eq 'FAIL' -or $r.Whea -gt 0){ $failed+=$c }
}
Write-Host "  =====================================================================" -ForegroundColor Cyan
try { $results.Values|Sort-Object Core|Export-Csv -Path $ReportPath -NoTypeInformation -Encoding UTF8; Write-Host ("  Report: {0}" -f $ReportPath) -ForegroundColor DarkGray } catch {}
$totalElapsed=((Get-Date)-$script:runStart).TotalSeconds
Write-Host ("  Total run time: {0}{1}" -f (Format-HMS $totalElapsed),$(if($script:abort){'  (stopped early)'}else{''}))
Write-Log ("=== RUN END === elapsed $(Format-HMS $totalElapsed) | failed: $($failed -join ',')")

if($failed.Count -eq 0 -and -not $script:abort){
    Write-Host ""; Write-Host "  All tested cores passed every profile. For real confidence:" -ForegroundColor Green
    Write-Host "     -Preset Overnight -Shuffle   (leave it running overnight)." -ForegroundColor Green
} elseif($failed.Count -gt 0){
    Write-Host ""; Write-Host ("  Unstable core(s): {0}" -f ($failed -join ', ')) -ForegroundColor Red
    if($failed.Count -ge $coreList.Count -and $coreList.Count -gt 1){
        Write-Host "  Every core failed -> suspect RAM/EXPO or a systemic issue; retest with EXPO off." -ForegroundColor Yellow }
    Write-Host "  Fix: raise the Curve Optimizer offset (less negative) on the failing cores." -ForegroundColor Yellow
    Write-Host "       The V-Cache CCD (often cores 0-7 on the 9950X3D) tolerates the least undervolt." -ForegroundColor Yellow
    Write-Host ("  Retest just those:  -Cores {0} -Preset Thorough" -f ($failed -join ',')) -ForegroundColor Yellow
}
Write-Host ""
