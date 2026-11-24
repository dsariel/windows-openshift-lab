# Feature 0007: Performance Benchmarking Suite

**Status:** Proposed | **Priority:** P1

## Summary
Performance benchmarking tools: DISKSPD (storage), ntttcp (network), Prime95 (CPU).

## Skills Demonstrated
Performance analysis, benchmarking tools, metrics collection, baseline establishment

## What We'll Learn
- DISKSPD for storage I/O (sequential/random, read/write, latency)
- ntttcp for network throughput
- Prime95/Cinebench for CPU stress
- JSON result format for comparison

## Proposal

**DISKSPD:**
```powershell
diskspd -c10G -d60 -r -w50 -t4 -o32 -b4K -Sh C:\testfile.dat
```

**ntttcp:**
```powershell
# Server: ntttcp -r -m 8,*,192.168.1.100 -p 5001
# Client: ntttcp -s -m 8,*,192.168.1.100 -p 5001 -t 60
```

## Testing
Establish baselines, compare SATA vs SCSI, e1000e vs virtio-net, detect regressions.

