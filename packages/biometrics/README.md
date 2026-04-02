# Biometrics Package

This package contains the reusable biometrics contracts for the public blueprint.

## What Ships Here

- provider interfaces for detector, embedder, PAD, and template protection layers
- deployment-profile catalog for public-release-safe capture paths and demo-only local runtimes
- deterministic demo capture analysis for local validation
- protected template projection logic
- latest-method stack metadata pinned to the current repo profile date
- evaluation helpers for PAD and OOD-style test scenarios
- a reproducible Core ML conversion helper at `packages/biometrics/scripts/convert_arcface_mobileface_to_coreml.py`

## What Does Not Ship Here

- restricted production model weights
- vendor SDK binaries
- non-commercial pretrained checkpoints

## iPhone Demo Note

The iPhone app now bundles a compiled `ArcFaceMobileFace.mlmodelc` demo embedder and uses
front `TrueDepth` capture plus depth-assisted liveness. Treat that path as an **iPhone demo
runtime**, not the repo's public-release-safe default deployment profile, unless your team has
reviewed the source model license, weight provenance, and replacement policy for your own release.
