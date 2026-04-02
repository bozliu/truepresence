# Operator SOP

This SOP is the shortest reliable way to run the **current reference deployment** of TruePresence.

## Authority-Side SOP

1. Open the authority console.
2. Add a person.
3. Start the Mac camera and complete guided enrollment.
4. Confirm the site location and start the live session.
5. Generate the QR code.
6. Watch the realtime decision feed during check-in.

## Mobile-Side SOP

1. Open the iPhone app.
2. Grant camera, location, and local network permissions.
3. Scan the authority QR code.
4. Confirm the readiness status is green:
   - location
   - same-LAN reachability
   - face verification
5. Enter the check-in flow.
6. Complete the TrueDepth verification.
7. Confirm the success screen or review the rejection reason.

## Reset SOP

1. Stop or replace the active live session.
2. Clear events only when the operator explicitly wants a clean slate.
3. Delete authority-added identities only when they are no longer needed.

## Reference Mapping

The shipped product currently maps these roles as:

- authority -> teacher
- mobile user -> student
- site -> classroom
- live session -> active class

## Reuse Mapping

The same SOP can be reused in other commercial settings:

- authority -> supervisor / dispatcher / site lead / manager
- mobile user -> worker / operator / field rep / attendee
- site -> field site / store / branch / route checkpoint / facility
- live session -> shift window / assignment window / visit window

## Why This SOP Is Reusable

It separates responsibilities cleanly:

- the authority side prepares trusted state
- the mobile side proves live presence
- the backend emits one canonical decision

That makes it easy to reuse for schools, training centers, field operations, retail site visits, route workflows, labs, or other controlled presence-verification systems.
