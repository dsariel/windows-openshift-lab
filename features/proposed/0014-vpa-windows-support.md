# Feature 0014: Vertical Pod Autoscaler (VPA) for Windows

**Status:** Proposed | **Priority:** P2

## Summary
Implement VPA for Windows pods (VPA 1.8.0 explicitly doesn't support Windows).

## Skills Demonstrated
Go (VPA, Kubernetes), Windows resource metrics, in-place pod resize, Job Objects

## What We'll Learn
- VPA architecture: Recommender, Updater, Admission Controller
- Windows Job Objects for resource limiting
- In-place resize API (K8s 1.35+)

## Proposal
Windows metrics provider → VPA recommender integration → admission controller for Windows → updater with resize logic

## Testing (Lab)
✅ Metrics collection, recommendations, admission controller
❌ Sustained autoscaling (needs long-term workloads)

**Upstream:** VPA project
