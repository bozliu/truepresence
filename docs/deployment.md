# Deployment Guide

## Reference LAN Deployment

This is the recommended first deployment mode for TruePresence.

### Start the backend

```bash
conda run -n dl uvicorn app.main:app --app-dir apps/api --host 0.0.0.0 --port 8000
```

### Open the authority console

[http://127.0.0.1:8000/teacher/](http://127.0.0.1:8000/teacher/)

### Connect the mobile iPhone

- connect the iPhone and authority host to the same Wi-Fi
- grant camera, location, and local network permissions
- use the authority-generated QR code to bind the mobile device

This reference setup is currently presented through a teacher/student workflow, but the same deployment shape also works for supervisor/worker, dispatcher/driver, or manager/field-rep products.

## Docker Deployment

```bash
docker build -t truepresence .
docker run --rm -p 8000:8000 truepresence
```

This is the easiest way to move from a single developer Mac to an edge or pilot deployment.

## Deployment Recommendations

- keep the authority console and backend together
- expose one canonical LAN URL to the mobile app
- prefer fixed local IPv4 over `.local` for reliability
- treat USB as an install/debug tool, not a runtime requirement

## Firewall and Networking

If the mobile iPhone cannot reach the authority backend:

1. make sure the backend is listening on `0.0.0.0`
2. confirm both devices are on the same Wi-Fi
3. confirm the authority host firewall allows inbound connections
4. confirm the mobile app has Local Network permission

## From Pilot to Product

The recommended commercial rollout path is:

1. one-operator pilot on a Mac
2. small edge box, branch mini-server, or classroom appliance
3. optional cloud synchronization for reporting or analytics

This progression keeps the product operationally simple while preserving a clean path to multi-site deployments.

## Vertical Mapping

The same deployment pattern can be reused as:

- education -> teacher console + student app + classroom site
- field workforce -> supervisor console + worker app + worksite geofence
- retail operations -> manager console + rep app + store visit site
- route logistics -> dispatcher console + driver app + checkpoint site

The public codebase ships the education-first UI today, but the deployment model is intentionally broader.
