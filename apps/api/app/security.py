from __future__ import annotations

import hmac
from hashlib import sha256

from .models import AttendanceClaimRequest, Tenant


def signing_message(claim: AttendanceClaimRequest) -> str:
    parts = [
        claim.tenant_id,
        claim.person_id or "",
        claim.site_id,
        claim.claimed_identity_mode,
        claim.client_timestamp.isoformat(),
        f"{claim.gps.latitude:.6f}",
        f"{claim.gps.longitude:.6f}",
        claim.app_version,
    ]
    return "|".join(parts)


def sign_claim(claim: AttendanceClaimRequest, tenant: Tenant) -> str:
    return hmac.new(
        tenant.api_secret.encode("utf-8"),
        signing_message(claim).encode("utf-8"),
        sha256,
    ).hexdigest()


def verify_claim_signature(claim: AttendanceClaimRequest, tenant: Tenant) -> bool:
    expected = sign_claim(claim, tenant)
    return hmac.compare_digest(expected, claim.request_signature)
