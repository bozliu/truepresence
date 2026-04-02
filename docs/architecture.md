# Architecture

## Goal

TruePresence answers one operational question:

> Was the right student physically present in the right classroom at the right time?

It does that with a local-first split between a **teacher authority surface** and a **student capture surface**.

## Core Design

- **Teacher Mac**
  - owns student creation
  - owns face enrollment
  - owns class session start/stop
  - acts as the classroom authority for LAN presence
  - receives the realtime attendance feed
- **Student iPhone**
  - requests permissions
  - binds to a student by QR
  - checks readiness: location, LAN, TrueDepth
  - captures the live face verification evidence
  - displays success and history
- **Backend**
  - stores public-safe fixtures and teacher-created records
  - issues binding tokens
  - validates attendance claims
  - publishes the canonical attendance event

## Trust Boundary

The most important design decision is that the teacher Mac is the classroom authority.

- The student app does **not** create students.
- The student app does **not** choose the class session.
- The student app does **not** produce a local-only “success” in classroom mode.
- The final decision lives on the backend so the teacher feed and student history stay consistent.

This trust boundary is useful for commercial systems because it keeps the operator experience predictable. A school or training organization can explain exactly where authority lives and audit that behavior later.

## Presence Model

TruePresence combines three live signals:

1. **Location**
   - the student device must be within the class geofence
2. **Same-LAN reachability**
   - the student iPhone must be able to reach the teacher Mac backend on the classroom Wi-Fi
3. **TrueDepth face verification**
   - the student must pass depth-backed face verification before claim submission

Any team reusing this repository can tune those signals independently, but the default value of the system comes from the combination rather than any single factor.

## Why LAN Reachability Instead of SSID/BSSID

Commercial Wi-Fi APIs on iPhone are constrained and fragile across deployment environments. This public release uses **teacher backend reachability on the same LAN** as the operational proof of classroom network presence.

That decision keeps the system:

- deployable with standard iOS permissions
- easier to explain to operators
- more robust across different school Wi-Fi setups

Teams that need hardware-level SSID or BSSID enforcement can add it later behind a separate policy adapter.

## Data Model

The backend keeps generic attendance entities so it stays reusable outside education:

- `tenant`
- `person`
- `site`
- `active_class_session`
- `attendance_event`
- `device_link`
- `protected_template`

The UI adds the education-specific meaning:

- `person` -> student
- `site` -> classroom
- `attendance_event` -> classroom check-in result

This separation makes the codebase easier to reuse in other environments such as workforce training, labs, or controlled facilities.

## Deployment Modes

### Recommended

- teacher backend on the Mac or an edge box
- teacher console served from the backend
- student iPhone on the same Wi-Fi

### Later extensions

- move the backend to a small edge server
- add cloud synchronization for reporting
- integrate school SIS or LMS systems
- add export pipelines for attendance records

The architecture is intentionally simple enough to pilot on one machine, but structured enough to grow into a multi-site product.
