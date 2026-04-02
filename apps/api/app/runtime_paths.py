from __future__ import annotations

import sys
from pathlib import Path


def ensure_local_pythonpaths() -> None:
    root = Path(__file__).resolve().parents[3]
    biometrics_src = root / "packages/biometrics/src"
    biometrics_str = str(biometrics_src)
    if biometrics_str not in sys.path:
        sys.path.insert(0, biometrics_str)
