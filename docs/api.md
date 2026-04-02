# API Overview

TruePresence exposes a compact set of backend contracts that map directly to the teacher/student workflow.

## Core Endpoints

### Teacher-facing

- `GET /v1/tenants`
  - list available tenants
- `GET /v1/demo/control/snapshot`
  - fetch teacher-console state, including class session, LAN URL, students, templates, captures, and recent events
- `POST /v1/demo/control/people`
  - create a teacher-added student
- `DELETE /v1/demo/control/people/{person_id}`
  - delete a teacher-added student
- `POST /v1/demo/control/enroll-from-mac`
  - enroll a student from a Mac camera capture or fallback upload
  - used by both guided camera capture and single-photo upload
- `POST /v1/demo/control/people/{person_id}/binding-token`
  - create a short-lived QR binding token for one student
- `POST /v1/demo/control/class-session/start`
  - start the active class session
- `POST /v1/demo/control/class-session/stop`
  - stop the active class session

### Student-facing

- `GET /v1/mobile/bootstrap`
  - fetch the classroom bootstrap for the iPhone
  - includes `linked_person`, `active_class_session`, `canonical_lan_url`, and LAN readiness data
- `POST /v1/mobile/device-link/claim`
  - claim a QR token and bind one iPhone to one student
- `POST /v1/attendance/claims`
  - submit a classroom attendance check-in
- `GET /v1/attendance/events`
  - fetch attendance history for a student or tenant

## Public Contract Principles

- the teacher console is responsible for **student management**
- the student app is responsible for **capture and proof**
- the backend is responsible for the **canonical decision**

That principle is what keeps the product easy to audit and easy to extend.

## Example Workflow Mapping

| Product action | Endpoint |
| --- | --- |
| teacher adds student | `POST /v1/demo/control/people` |
| teacher enrolls face | `POST /v1/demo/control/enroll-from-mac` |
| teacher starts class | `POST /v1/demo/control/class-session/start` |
| teacher generates QR | `POST /v1/demo/control/people/{person_id}/binding-token` |
| student binds device | `POST /v1/mobile/device-link/claim` |
| student checks in | `POST /v1/attendance/claims` |
| both sides refresh history | `GET /v1/attendance/events` |

## Notes for Reuse

- The route prefix still uses `/v1/demo/control/...` for compatibility with the current codebase.
- The public semantics are classroom-oriented even where the internal type names stay generic.
- Teams can layer additional policy checks on top of the existing contracts without changing the operator flow.
- The shipped mobile reference app uses Vision face detection, a bundled `ArcFaceMobileFace.mlmodelc` Core ML embedder, and TrueDepth-assisted liveness before claim submission.
