# Security & Privacy Defaults

## Default Posture

TruePresence is designed to be conservative by default.

- protected templates are stored instead of raw face embeddings
- classroom mode relies on one canonical backend decision source
- local fallback “success” is not used in classroom mode
- the public repository ships no personal captures or real student templates

## Data Categories

### Stored by default

- tenant metadata
- student records
- classroom records
- protected template records
- attendance events
- device binding records

### Not shipped in this public repo

- real face captures
- real student templates
- private network addresses
- internal operator logs
- company-specific project traces

## Why Protected Templates Matter

The repository keeps a template-protection boundary because public attendance systems should not normalize storing raw biometric features without a reason. Teams reusing this project can change the protection scheme, but the boundary itself is operationally important.

## Operational Recommendations

- keep the teacher backend on a trusted classroom machine or edge box
- rotate any production signing secrets
- keep evidence retention off unless policy requires it
- treat class session start/stop as auditable events
- restrict destructive admin actions in production deployments

## Public Release Limitations

This repository is a public-safe starting point, not a compliance certification. Before commercial rollout, teams should add:

- production key management
- identity and access control for teacher accounts
- audit logging
- deployment hardening
- legal/privacy review for the target jurisdiction
