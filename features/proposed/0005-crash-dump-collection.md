# Feature 0005: Crash Dump Collection

**Status:** Proposed | **Priority:** P1

## Summary
Automate Windows crash dump collection to PVC and WinDbg analysis.

## Skills Demonstrated
Kernel debugging, crash analysis, WinDbg, Windows registry, PVC management

## What We'll Learn
- Windows crash dump configuration (kernel, complete, mini)
- Registry: `CrashControl\CrashDumpEnabled`, `\DumpFile`
- WinDbg automation and symbol servers
- Crash injection with NotMyFault.exe

## Proposal

**Registry Configuration:**
```powershell
Set-ItemProperty HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl `
  -Name CrashDumpEnabled -Value 1  # 1=complete, 2=kernel, 3=mini
Set-ItemProperty HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl `
  -Name DumpFile -Value 'D:\crash-dumps\MEMORY.DMP'
```

**WinDbg Automation:**
```powershell
windbg -z MEMORY.DMP -c "!analyze -v; .logopen analysis.txt; .logclose; q"
```

**VM Spec:**
```yaml
volumes:
  - name: crash-dumps
    persistentVolumeClaim:
      claimName: windows-crash-pvc
volumeMounts:
  - name: crash-dumps
    mountPath: "D:"
```

## Testing
Inject crash with NotMyFault.exe, verify dump collected, analyze with WinDbg.

