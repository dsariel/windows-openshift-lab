# Feature 0017: Cluster-Wide Proxy Support for Windows Workloads

**Status:** Proposed | **Priority:** P1

## Summary
Enable Windows nodes in clusters with cluster-wide proxy (OpenShift 4.22 limitation).

## Skills Demonstrated
Go (WMCO), Windows proxy config (WinHTTP, WinINet), PowerShell, containerd proxy

## What We'll Learn
- OpenShift cluster proxy CR (config.openshift.io/v1/Proxy)
- WinHTTP proxy settings (netsh winhttp)
- Containerd and kubelet proxy configuration

## Proposal
WMCO reads cluster proxy CR → extract settings → configure Windows (netsh winhttp, env vars) → update containerd config → update kubelet config

**PowerShell:**
```powershell
netsh winhttp set proxy proxy-server="proxy:3128" bypass-list="localhost;.svc"
[Environment]::SetEnvironmentVariable('HTTP_PROXY', 'http://proxy:3128', 'Machine')
```

## Testing (Lab)
✅ Fully testable: local Squid proxy, cluster proxy CR, image pull through proxy

**Upstream:** WMCO
