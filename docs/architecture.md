# Architecture

## Goal

TruePresence answers one operational question:

> Was the right person physically present at the right site, in the right local context, at the right time?

The shipped public UI demonstrates that question through an education-first reference deployment:

- authority surface -> teacher Mac
- mobile capture surface -> student iPhone
- site -> classroom

The underlying architecture is intentionally broader than that first vertical.

## Core Design

- **Authority surface**
  - owns person creation
  - owns face enrollment
  - owns live session start and stop
  - acts as the site authority for LAN presence
  - receives the realtime decision feed
- **Mobile capture surface**
  - requests permissions
  - binds to a person by QR
  - checks readiness: location, LAN, TrueDepth
  - captures live face verification evidence
  - displays success and history
- **Backend**
  - stores public-safe fixtures and authority-created records
  - issues binding tokens
  - validates presence claims
  - publishes the canonical attendance event

## Trust Boundary

The most important design decision is that the authority device owns session state and final decisioning.

- The mobile app does **not** create people.
- The mobile app does **not** choose the live session.
- The mobile app does **not** emit a local-only “success” in reference LAN mode.
- The final decision lives on the backend so the authority feed and mobile history stay consistent.

This trust boundary is useful commercially because it keeps the operator experience explainable and auditable. A school, construction manager, branch lead, or dispatcher can all point to one clear authority source.

## Presence Model

TruePresence combines three live signals:

1. **Location**
   - the mobile device must be within the configured site geofence
2. **Same-LAN reachability**
   - the mobile device must be able to reach the authority backend on the active local network
3. **TrueDepth face verification**
   - the mobile user must pass depth-backed face verification before claim submission

Any team reusing this repository can tune those signals independently, but the default value of the system comes from the combination rather than any single factor.

## Why LAN Reachability Instead of SSID/BSSID

Commercial Wi-Fi APIs on iPhone are constrained and fragile across deployment environments. This public release uses **authority backend reachability on the same LAN** as the operational proof of network presence.

That choice keeps the system:

- deployable with standard iOS permissions
- easier to explain to operators
- more robust across classrooms, branches, job sites, and managed LANs

Teams that need hardware-level SSID or BSSID enforcement can add it later behind a dedicated policy adapter.

## Data Model

The backend keeps generic attendance entities so it stays reusable outside education:

- `tenant`
- `person`
- `site`
- `active_class_session`
- `attendance_event`
- `device_link`
- `protected_template`

The current reference UI applies education-specific meaning:

- `person` -> student
- `site` -> classroom
- `attendance_event` -> classroom check-in result

That mapping is intentionally thin. The same entities can be reused as:

- `person` -> worker / field rep / driver / attendee
- `site` -> branch / checkpoint / client site / facility
- `attendance_event` -> shift start / visit verification / site arrival proof

## Deployment Modes

### Recommended reference deployment

- authority backend on a Mac or edge box
- authority console served from the backend
- mobile iPhone on the same Wi-Fi

### Later extensions

- move the backend to a small edge server
- add cloud synchronization for reporting
- integrate SIS, LMS, workforce, or route-management systems
- add export pipelines for operational records

The architecture is intentionally simple enough to pilot on one machine, but structured enough to grow into a multi-site product.

## Role Mapping For Reuse

The current public repo is education-first, but the roles are reusable:

- teacher -> supervisor / dispatcher / site lead / manager
- student -> worker / operator / field rep / attendee
- classroom -> field site / store / branch / route checkpoint
- active class session -> live shift window / assignment window / visit window

This is why the repo is positioned as a **presence verification platform** rather than a classroom-only demo.
