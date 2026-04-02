from __future__ import annotations

import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SELF_AUDIT_PATH = Path(__file__).resolve()


def token(*parts: str) -> str:
    return "".join(parts)


FORBIDDEN_PATTERNS = {
    "legacy company reference": re.compile(r"\b" + token("Pana", "sonic") + r"\b"),
    "personal home path": re.compile(re.escape(token("/", "Users", "/", "boz", "liu"))),
    "personal static IP": re.compile(re.escape(token("192", ".", "168", ".", "0", ".", "119"))),
    "personal Xcode team": re.compile(re.escape(token("34G3", "4W2P", "YR"))),
    "legacy personal fixture name A": re.compile(r"\b" + token("Boz", "hong") + r"\b", re.IGNORECASE),
    "legacy personal fixture name B": re.compile(r"\b" + token("Ali", "na") + r"\b", re.IGNORECASE),
    "legacy personal fixture name C": re.compile(r"\b" + token("Haru", "to") + r"\b", re.IGNORECASE),
    "internal memory doc A": re.compile(r"\b" + re.escape(token("Prompt", ".md")) + r"\b"),
    "internal memory doc B": re.compile(r"\b" + re.escape(token("Plan", ".md")) + r"\b"),
    "internal memory doc C": re.compile(r"\b" + re.escape(token("Implement", ".md")) + r"\b"),
    "internal memory doc D": re.compile(r"\b" + re.escape(token("Documentation", ".md")) + r"\b"),
    "machine hostname": re.compile(
        re.escape(token("MacBook", "-Pro", ".local"))
        + "|"
        + re.escape(token("teacher", "-mac", ".local"))
    ),
}

TEXT_EXTENSIONS = {
    ".md",
    ".py",
    ".swift",
    ".js",
    ".json",
    ".plist",
    ".toml",
    ".yml",
    ".yaml",
    ".html",
    ".css",
    ".pbxproj",
    ".dockerignore",
    ".gitignore",
}

MARKDOWN_LINK_RE = re.compile(r"!\[[^\]]*\]\(([^)]+)\)|\[[^\]]+\]\(([^)]+)\)")


def tracked_text_files() -> list[Path]:
    files: list[Path] = []
    for path in ROOT.rglob("*"):
        if path.is_dir():
            if path.name in {".git", "__pycache__", ".pytest_cache", "node_modules"}:
                continue
            continue
        if path.suffix.lower() in TEXT_EXTENSIONS or path.name in {".gitignore", ".dockerignore"}:
            files.append(path)
    return files


def scan_forbidden_patterns(files: list[Path]) -> list[str]:
    issues: list[str] = []
    for path in files:
        if path.resolve() == SELF_AUDIT_PATH:
            continue
        text = path.read_text(encoding="utf-8", errors="ignore")
        for label, pattern in FORBIDDEN_PATTERNS.items():
            if pattern.search(text):
                issues.append(f"{label}: {path.relative_to(ROOT)}")
    return issues


def scan_markdown_links(files: list[Path]) -> list[str]:
    issues: list[str] = []
    for path in files:
        if path.suffix.lower() != ".md":
            continue
        text = path.read_text(encoding="utf-8", errors="ignore")
        for match in MARKDOWN_LINK_RE.finditer(text):
            raw = match.group(1) or match.group(2) or ""
            target = raw.strip()
            if not target or target.startswith(("http://", "https://", "mailto:", "#", "data:")):
                continue
            target = target.split("?", 1)[0].split("#", 1)[0]
            candidate = (path.parent / target).resolve()
            if not candidate.exists():
                issues.append(f"Broken markdown link in {path.relative_to(ROOT)} -> {target}")
    return issues


def scan_for_runtime_artifacts() -> list[str]:
    issues: list[str] = []
    for relative in ("data/runtime", "output"):
        candidate = ROOT / relative
        if candidate.exists():
            issues.append(f"Runtime artifact directory present: {relative}")
    for path in ROOT.rglob(".DS_Store"):
        issues.append(f"macOS artifact present: {path.relative_to(ROOT)}")
    return issues


def main() -> int:
    files = tracked_text_files()
    issues = []
    issues.extend(scan_forbidden_patterns(files))
    issues.extend(scan_markdown_links(files))
    issues.extend(scan_for_runtime_artifacts())
    if issues:
        print("Public release audit failed:")
        for issue in issues:
            print(f" - {issue}")
        return 1
    print("Public release audit passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
