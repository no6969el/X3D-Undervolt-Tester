<#
==============================================================================
 Test-UndervoltStability.ps1   v3  -- "X3D CO Killer"
------------------------------------------------------------------------------
 A single-core stress + CORRECTNESS-VERIFICATION tester that hunts unstable
 Curve Optimizer / negative-offset undervolts by hitting EVERY corner of each
 core's voltage/frequency curve -- not just one load type.

 WHY THIS CATCHES WHAT OTHERS MISS
   Curve Optimizer instability is operating-point specific. A core can pass a
   heavy AVX-512 furnace for hours yet reboot while browsing, because the two
   sit at completely different points on the V/F curve. So this tool tests each
   core with THREE profiles, and verifies the math on all of them:

     BOOST      scalar, 1 thread  -> highest frequency, lowest voltage
                (the "crashes at idle" corner; usually the easiest CO fail)
     TRANSIENT  heavy, both SMT threads, toggled on/off every few ms
                -> di/dt voltage swings the VRM can't track (the killer)
     HEAVY      widest vectors (AVX-512), sustained, max current
                -> the droop-under-load corner

   Every block of work is deterministic and checked against a per-core
   reference; a single wrong bit is caught as an ERROR before a BSOD. WHEA
   hardware errors and hangs are captured too, and the core under test is
   logged BEFORE it runs so a hard lock still names the guilty core.

 REQUIRES PowerShell 7.4+ (pwsh.exe) for AVX-512. Run ELEVATED is recommended.

 QUICK START:
   pwsh -File .\Test-UndervoltStability.ps1                 # Standard (all 3 profiles)
   pwsh -File .\Test-UndervoltStability.ps1 -Preset Extreme -Shuffle
   pwsh -File .\Test-UndervoltStability.ps1 -Mode Transient # just the di/dt killer
   pwsh -File .\Test-UndervoltStability.ps1 -Cores 3,11     # retest suspects

 -SecondsPerCore is PER PROFILE. "All" runs Boost + Transient + Heavy per core.
==============================================================================
#>

param(
    [ValidateSet('Quick','Standard','Thorough','Overnight','Extreme')]
    [string] $Preset,
    [int]    $SecondsPerCore,
    [int]    $Cycles,
    [ValidateSet('All','Boost','Mid','Heavy','Transient')]
    [string] $Mode,
    [int]    $ThreadsPerCore = 1,     # threads for the HEAVY profile (1 or 2)
    [switch] $IncludeMid,             # add an AVX2 mid-curve profile
    [int]    $TransientOnMs  = 3,     # di/dt: load-on window (ms)
    [int]    $TransientOffMs = 3,     # di/dt: idle window (ms)
    [switch] $TransientSweep,         # sweep the toggle period to hit VRM resonances
    [int[]]  $Cores,
    [switch] $Shuffle,
    [switch] $StopOnError,
    [switch] $NoClocks,
    [switch] $NoAvx512,
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

# ---------------------------------------------------------------------------
#  Kernels. One class per instruction set, generated from a shared template.
#  Verification is SELF-REFERENCING (each worker derives its own golden from
#  its first blocks), so different profiles can use different instruction sets
#  without any cross-process hash mismatch.
# ---------------------------------------------------------------------------
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

switch ($Preset) {
    'Quick'     { $d=@{Mode='All';SecondsPerCore=90; Cycles=1;Shuffle=$false} }
    'Standard'  { $d=@{Mode='All';SecondsPerCore=150;Cycles=1;Shuffle=$false} }
    'Thorough'  { $d=@{Mode='All';SecondsPerCore=300;Cycles=2;Shuffle=$true } }
    'Overnight' { $d=@{Mode='All';SecondsPerCore=600;Cycles=6;Shuffle=$true } }
    'Extreme'   { $d=@{Mode='All';SecondsPerCore=300;Cycles=3;Shuffle=$true } }
    default     { $d=@{Mode='All';SecondsPerCore=150;Cycles=1;Shuffle=$false} }
}
if (-not $PSBoundParameters.ContainsKey('Mode'))          { $Mode           = $d.Mode }
if (-not $PSBoundParameters.ContainsKey('SecondsPerCore')) { $SecondsPerCore = $d.SecondsPerCore }
if (-not $PSBoundParameters.ContainsKey('Cycles'))         { $Cycles         = $d.Cycles }
if (-not $PSBoundParameters.ContainsKey('Shuffle') -and $d.Shuffle) { $Shuffle = [switch]$true }
if ($Preset -eq 'Extreme') { $IncludeMid = [switch]$true; $TransientSweep = [switch]$true; if (-not $PSBoundParameters.ContainsKey('ThreadsPerCore')) { $ThreadsPerCore = 2 } }

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
$heavyThreads = if($smtOn){[math]::Min($ThreadsPerCore,2)}else{1}
$coreList = if($Cores){@($Cores|Where-Object{$coreMasks.ContainsKey($_)})}else{@(0..($physCores-1))}
if(-not $coreList){ Write-Host "No valid cores." -ForegroundColor Red; return }

# ---- Calibrate iters-per-block for each compiled kernel ----
function Get-Iters { param([string]$ClassName,[double]$TargetMs)
    $T=[type]$ClassName
    $probe=200000
    $t=Measure-Command { [void]$T.GetMethod('Block').Invoke($null,@([int]$probe)) }
    $per=$t.TotalSeconds/$probe
    [int][math]::Max(1000,[math]::Round(($TargetMs/1000.0)/[math]::Max($per,1e-12)))
}

# ---- Build the profile plan ----
# each profile: Name, Kernel(class), Pattern, Threads, MaskKey(one/both), BlockIters, OnMs, OffMs, Sweep
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

if ($wantBoost)     { Add-Profile 'BOOST'     'scalar'  'sustained' 1                                 'one'  100 }
if ($wantMid)       { Add-Profile 'MID'       $midKey   'sustained' 1                                 'one'  100 }
if ($wantTransient) { Add-Profile 'TRANSIENT' $wideKey  'transient' $(if($smtOn){2}else{1})           'both' 0.4 }
if ($wantHeavy)     { Add-Profile 'HEAVY'     $wideKey  'sustained' $heavyThreads                     $(if($heavyThreads -ge 2){'both'}else{'one'}) 100 }
if (-not $profiles) { Write-Host "No profiles selected for Mode '$Mode'." -ForegroundColor Red; return }

# ---- Crash forensics from prior run ----
if (Test-Path $LogPath) {
    try {
        $tail=Get-Content $LogPath -Tail 100; $suspect=$null; $idx=-1
        for($j=$tail.Count-1;$j -ge 0;$j--){ if($tail[$j] -match 'begin core (\d+)'){ $suspect=$matches[1]; $idx=$j; break } }
        if($null -ne $suspect){
            $after=$tail[$idx..($tail.Count-1)]
            if(-not (($after -match ("core {0}\b.*(PASS|FAIL|WHEA|REF)" -f $suspect)) -or ($after -match 'RUN END'))){
                Write-Host ""; Write-Host "  !! A previous run stopped while testing Core $suspect with no result recorded." -ForegroundColor Magenta
                Write-Host "     If that was a hard lock/BSOD, Core $suspect is your prime suspect." -ForegroundColor Magenta
            }
        }
    } catch {}
}

# ---- Banner ----
$vecName = switch ($wideKey) { 'avx512' {'AVX-512 512-bit'} 'simd' {'AVX2 256-bit'} default {'scalar'} }
Write-Host ""
Write-Host "  X3D Undervolt CO Killer  (v3)" -ForegroundColor Cyan
Write-Host "  =============================" -ForegroundColor Cyan
Write-Host ("  CPU        : {0}" -f $cpu.Name.Trim())
Write-Host ("  Cores      : {0} physical / {1} logical (SMT {2})" -f $physCores,$logCores,($(if($smtOn){'on'}else{'off'})))
Write-Host ("  Kernels    : {0}   (heavy/transient use {1})" -f (($Kernels.Keys|Sort-Object) -join ', '), $vecName)
Write-Host ("  PowerShell : {0} ({1})" -f $PSVersionTable.PSVersion,$PSVersionTable.PSEdition)
if ($wideKey -ne 'avx512' -and -not $NoAvx512) {
    Write-Host "               (AVX-512 not active: needs PowerShell 7.4+/.NET 8+ on an AVX-512 CPU.)" -ForegroundColor DarkGray
}
Write-Host ("  Profiles/core:")
foreach($p in $profiles){
    $extra = if($p.Pattern -eq 'transient'){ if($p.Sweep){"toggle sweep 2-17ms, 2 threads"}else{"toggle $($p.OnMs)/$($p.OffMs)ms, $($p.Threads) threads"} } else { "$($p.Threads) thread(s)" }
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
Write-Log "=== RUN START === $($cpu.Name.Trim()) | wide=$vecName | mode=$Mode | $($coreList.Count)c x $Cycles cy x $($profiles.Count)prof x ${SecondsPerCore}s"

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
