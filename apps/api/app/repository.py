from __future__ import annotations

import json
from pathlib import Path
from threading import Lock

from .models import RepositoryState


class JsonRepository:
    def __init__(self, path: Path) -> None:
        self.path = path
        self.lock = Lock()
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.state = self._load()

    def _load(self) -> RepositoryState:
        if not self.path.exists():
            return RepositoryState()
        payload = json.loads(self.path.read_text(encoding="utf-8"))
        return RepositoryState.model_validate(payload)

    def save(self) -> None:
        with self.lock:
            payload = self.state.model_dump(mode="json")
            self.path.write_text(json.dumps(payload, indent=2), encoding="utf-8")

    def snapshot(self) -> RepositoryState:
        return self.state
