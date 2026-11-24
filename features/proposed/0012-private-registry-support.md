# Feature 0012: Private Registry Support for Windows Nodes

**Status:** Proposed | **Priority:** P1

## Summary
Enable Windows nodes to pull from private registries (OpenShift 4.22 limitation).

## Skills Demonstrated
Go (WMCO), Windows certificate store, PowerShell, containerd registry config, imagePullSecrets

## What We'll Learn
- Windows certificate store (Cert:\LocalMachine\Root)
- Containerd config.toml registry configuration
- imagePullSecrets handling on Windows

## Proposal
WMCO watches registry secrets → copy certs to Windows → import to cert store → update containerd config → restart service

**PowerShell:**
```powershell
Import-Certificate -FilePath ca.crt -CertStoreLocation Cert:\LocalMachine\Root
netsh winhttp set proxy proxy-server="registry:5000"
```

## Testing (Lab)
✅ Fully testable: local registry with TLS, imagePullSecrets, pod deployment

**Upstream:** WMCO
