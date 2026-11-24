# Feature 0006: Windows Debugging Infrastructure

**Status:** Proposed | **Priority:** P1

## Summary
WinDbg installation, symbol server configuration, kernel debugging setup.

## Skills Demonstrated
WinDbg, symbol servers, kernel debugging, kdnet, debugging protocols

## What We'll Learn
- WinDbg installation and configuration
- Microsoft public symbol server
- Symbol path: `SRV*C:\Symbols*https://msdl.microsoft.com/download/symbols`
- Kernel debugging via kdnet (network debugging)
- Reading crash dumps, stack traces, analyzing !analyze output

## Proposal

**Symbol Server Setup:**
```powershell
setx _NT_SYMBOL_PATH "SRV*C:\Symbols*https://msdl.microsoft.com/download/symbols"
```

**Kernel Debug (kdnet):**
```powershell
bcdedit /debug on
bcdedit /dbgsettings net hostip:192.168.122.1 port:50000
# Boot, connect from host: windbg -k net:port=50000,key=...
```

## Testing
Analyze crash dump with symbols, verify symbol resolution, test live kernel debugging.

