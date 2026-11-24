# Feature 0018: User-Defined Project Monitoring for Windows

**Status:** Proposed | **Priority:** P2

## Summary
Enable OpenShift user-defined monitoring for Windows nodes (OpenShift 4.22 limitation).

## Skills Demonstrated
Go (Prometheus exporters), windows_exporter, ServiceMonitor, Prometheus Operator, PromQL

## What We'll Learn
- OpenShift monitoring stack integration
- windows_exporter (Prometheus exporter for Windows)
- ServiceMonitor and PodMonitor CRDs
- Grafana dashboard creation

## Proposal
WMCO deploys windows_exporter → ServiceMonitor for discovery → Prometheus scraping → Grafana dashboards → alert rules

**ServiceMonitor:**
```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: windows-exporter
spec:
  selector:
    matchLabels:
      app: windows-exporter
  endpoints:
  - port: metrics
    interval: 30s
```

## Testing (Lab)
✅ Fully testable: windows_exporter, metrics scraping, Prometheus queries, dashboards

**Upstream:** WMCO
