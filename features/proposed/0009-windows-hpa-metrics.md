# Feature 0009: Windows Pod Metrics for HPA

**Status:** Proposed | **Priority:** P2

## Summary
Enable HPA for Windows pods by implementing metrics collection from Windows nodes.

## Skills Demonstrated
Go (Kubernetes controllers), Windows performance counters, Prometheus, metrics-server integration

## What We'll Learn
- Windows performance counters (\Processor, \Memory, \Network)
- metrics-server architecture and Windows node support
- prometheus/client_golang library

## Proposal
Build windows-exporter (Go) → collect per-pod CPU/memory → expose Prometheus endpoint → integrate with WMCO → metrics-server aggregation

## Testing (Lab)
✅ Exporter development, Prometheus scraping, per-pod metrics
❌ Full HPA (needs cluster metrics aggregation)

**Upstream:** WMCO, metrics-server
