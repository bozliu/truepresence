# Evaluation Methodology

## Why This Document Exists

Public release metrics are only useful if readers understand what they mean and how to reproduce them. This document explains the reference numbers in the README and how to adapt them to another deployment.

## Reference Setup

The timing table in the README was generated from the backend using:

- FastAPI `TestClient`
- Apple Silicon Mac
- public-safe bootstrap fixtures
- one teacher-added student with one enrolled template

These numbers measure **backend decision overhead**, not end-to-end classroom UX.

## Reference Timing Results

| Endpoint | Median | P95 | Interpretation |
| --- | ---: | ---: | --- |
| `GET /v1/mobile/bootstrap` | `0.91 ms` | `1.03 ms` | how quickly the backend can answer “what class is active and what student is bound?” |
| `POST /v1/mobile/device-link/claim` | `0.72 ms` | `0.84 ms` | how quickly a scanned QR token can bind an iPhone to a student |
| `POST /v1/attendance/claims` | `4.11 ms` | `4.42 ms` | how quickly the backend can evaluate a classroom attendance claim once evidence is already captured |

## What These Results Mean

- They are **not camera latency**.
- They are **not Wi-Fi latency**.
- They are **not UI latency**.
- They are useful because they isolate backend budget.

If your backend overhead is already tiny, your optimization work should focus on:

- device capture quality
- network stability
- teacher workflow ergonomics
- enrollment robustness

## Reuse Guidance

Teams can reuse this evaluation method in three ways:

1. **compare deployment targets**
   - Mac mini vs. classroom PC vs. edge box
2. **compare backend changes**
   - policy engine refactors
   - template-matching changes
3. **compare product configurations**
   - LAN-only classroom mode vs. remote sync overlays

## Behavior Validation

The automated test suite also validates key product behaviors:

| Scenario | Expected result |
| --- | --- |
| valid onsite claim | `accepted` |
| outside geofence | `outside_geofence` |
| malformed teacher session request | validation error |
| QR device binding | successful binding to linked student |
| LAN classroom claim with enrolled student | accepted server decision |
| class-session gating | student cannot proceed without class state |

These tests are useful beyond this repo. They form a reusable acceptance checklist for anyone building classroom or site-presence systems.
