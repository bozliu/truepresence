from __future__ import annotations

import hashlib
import hmac

from .contracts import ProtectedTemplate
from .demo import normalize


class ProjectionTemplateProtector:
    def __init__(self, secret: str, dimension: int = 256) -> None:
        self.secret = secret.encode("utf-8")
        self.dimension = dimension

    def protect(self, embedding_vector: list[float]) -> ProtectedTemplate:
        vector = normalize(embedding_vector)
        if not vector:
            raise ValueError("embedding_vector must not be empty")

        bits: list[str] = []
        for index in range(self.dimension):
            score = 0.0
            for projection_round in range(8):
                digest = hashlib.sha256(
                    self.secret + f":{index}:{projection_round}".encode("utf-8")
                ).digest()
                position = digest[0] % len(vector)
                sign = 1.0 if digest[1] % 2 == 0 else -1.0
                weight = 0.5 + (digest[2] / 255.0)
                score += vector[position] * sign * weight
            bits.append("1" if score >= 0 else "0")

        bitstring = "".join(bits)
        digest = hmac.new(self.secret, bitstring.encode("utf-8"), hashlib.sha256).hexdigest()
        return ProtectedTemplate(
            scheme="signed-random-projection-v1",
            dimension=self.dimension,
            bitstring=bitstring,
            digest=digest,
        )

    def similarity(self, left: ProtectedTemplate, right: ProtectedTemplate) -> float:
        if left.dimension != right.dimension:
            raise ValueError("template dimensions must match")
        matches = sum(1 for lhs, rhs in zip(left.bitstring, right.bitstring) if lhs == rhs)
        return matches / left.dimension
