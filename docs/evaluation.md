# Evaluation Methodology

## Why This Document Exists

Public release metrics are only useful if readers understand what they mean and how to reproduce them. This document explains the reference numbers in the README and how to adapt them to another deployment.

## Reference Setup

The timing table in the README was generated from the backend using:

- FastAPI `TestClient`
- Apple Silicon Mac
- public-safe bootstrap fixtures
- one authority-created identity with one enrolled template

These numbers measure **backend decision overhead**, not end-to-end UI latency.

## Reference Timing Results

| Endpoint | Median | P95 | Interpretation |
| --- | ---: | ---: | --- |
| `GET /v1/mobile/bootstrap` | `0.91 ms` | `1.03 ms` | how quickly the backend can answer “what live session is active and what identity is bound?” |
| `POST /v1/mobile/device-link/claim` | `0.72 ms` | `0.84 ms` | how quickly a scanned QR token can bind an iPhone to one identity |
| `POST /v1/attendance/claims` | `4.11 ms` | `4.42 ms` | how quickly the backend can evaluate a presence claim once evidence is already captured |

## What These Results Mean

- They are **not camera latency**.
- They are **not Wi-Fi latency**.
- They are **not UI latency**.
- They are useful because they isolate backend budget.

If your backend overhead is already tiny, your optimization work should focus on:

- device capture quality
- network stability
- operator workflow ergonomics
- enrollment robustness

## Reuse Guidance

Teams can reuse this evaluation method in three ways:

1. **compare deployment targets**
   - Mac mini vs. laptop vs. edge box
2. **compare backend changes**
   - policy engine refactors
   - template-matching changes
3. **compare product configurations**
   - classroom reference mode vs. field attendance mode vs. site-presence mode

## Behavior Validation

The automated test suite also validates key product behaviors:

| Scenario | Expected result |
| --- | --- |
| valid onsite claim | `accepted` |
| outside geofence | `outside_geofence` |
| malformed session request | validation error |
| QR device binding | successful binding to linked identity |
| LAN claim with enrolled identity | accepted server decision |
| session gating | mobile user cannot proceed without active session |

These tests are useful beyond this repo. They form a reusable acceptance checklist for anyone building classroom, workforce, or controlled site-presence systems.

## Current Reference Vertical vs. Broader Platform

The shipped UI is education-first today, so the most concrete test story is still:

- teacher starts class
- student binds and checks in

But the evaluation model itself is already broader:

- authority creates the live session
- mobile device submits presence evidence
- backend emits one canonical decision

That pattern is reusable in field operations, retail site visits, route checkpoints, and controlled remote workflows.
