# Deployment Guide

## Local LAN Classroom Mode

This is the reference deployment mode for TruePresence.

### Start the backend

```bash
conda run -n dl uvicorn app.main:app --app-dir apps/api --host 0.0.0.0 --port 8000
```

### Open the teacher console

[http://127.0.0.1:8000/teacher/](http://127.0.0.1:8000/teacher/)

### Connect the student iPhone

- connect the iPhone and Mac to the same Wi-Fi
- grant camera, location, and local network permissions
- use the teacher-generated QR code to bind the student device

## Docker Deployment

```bash
docker build -t truepresence .
docker run --rm -p 8000:8000 truepresence
```

This is the easiest way to move from a single developer Mac to a small edge or pilot deployment.

## Deployment Recommendations

- keep the teacher console and backend together
- expose one canonical LAN URL to the student app
- prefer fixed local IPv4 over `.local` for classroom reliability
- treat USB as an install/debug tool, not a runtime requirement

## Firewall and Networking

If the student iPhone cannot reach the teacher backend:

1. make sure the backend is listening on `0.0.0.0`
2. confirm both devices are on the same Wi-Fi
3. confirm the teacher Mac firewall allows inbound connections
4. confirm the student app has Local Network permission

## From Pilot to Product

The recommended commercial rollout path is:

1. one-teacher pilot on a Mac
2. small edge box or classroom mini-server
3. optional cloud synchronization for reporting or analytics

This progression keeps the product operationally simple while preserving a clean path to multi-site deployments.
