import argparse
import hashlib
import pathlib
import re
import subprocess
import sys


ROOT_FILES = {
    ".gitignore", "AGENTS.md", "CLAUDE.md", "CONTRIBUTING.md", "LICENSE",
    "PRIVACY.md", "README.md", "SECURITY.md", "THIRD_PARTY.md", "Package.swift",
    "Open AgentTrail.command",
}
DIRECTORY_SUFFIXES = {
    "Sources": {".swift", ".h", ".modulemap"},
    "Tests": {".swift"},
    "Resources": {".plist"},
    "docs": {".md"},
    "scripts": {".py", ".sh"},
    ".github": {".yml", ".yaml", ".md"},
}
REVIEWED_IMAGES = {
    "Resources/AppIcon.png": "26e6bbd7081bdf09c358b505e90011a0cd02b5746f1d12956d516a73b605acd4",
    "Resources/AppIcon.icns": "4c5ff7b7cbbb47092f0bffd19734ecd6f6d7692529912d7581f3729e52e510f5",
    "docs/assets/timeline.jpg": "5a4f14bb0f695ffc66e1008bb0dfa57a384166d66410beacdee1d4a616c0792f",
    "docs/assets/cursor-trail.jpg": "d094b2ec22268127a3178f7134e455ed3f62304df0cb5d01573ef997294f6d69",
}
PATTERNS = {
    "private key": re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----"),
    "GitHub credential": re.compile(r"\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,})\b"),
    "cloud access key": re.compile(r"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b"),
    "model API credential": re.compile(r"\bsk-(?:proj-|svcacct-)?[A-Za-z0-9_-]{32,}\b"),
    "messaging credential": re.compile(r"\bxox[baprs]-[A-Za-z0-9-]{20,}\b"),
    "literal credential assignment": re.compile(r'''(?i)\b(?:api[_-]?key|access[_-]?token|client[_-]?secret|password)\s*[:=]\s*["'][A-Za-z0-9_./+=-]{16,}["']'''),
    "personal home path": re.compile(r"(?:/Users/|/home/)[A-Za-z0-9_.-]+(?:/|$)|\b[A-Z]:\\Users\\[A-Za-z0-9_. -]+\\"),
    "personal email": re.compile(r"(?i)\b[A-Za-z0-9._%+-]+@(?:gmail\.com|icloud\.com|outlook\.com|hotmail\.com|yahoo\.com)\b"),
    "serialized recording": re.compile(r'''(?m)^\s*\{[^\n]*"sessionID"\s*:[^\n]*"timestamp"\s*:\s*\d'''),
}


def check_blob(name, mode, data, deny_terms=()):
    problems = []
    location = pathlib.PurePosixPath(name)
    if mode not in {"100644", "100755"}:
        problems.append("symlink, submodule, or unsupported file mode")
    if name in REVIEWED_IMAGES:
        if mode != "100644":
            problems.append("reviewed image must be a regular non-executable file")
        if location.suffix == ".jpg":
            valid_format = len(data) <= 512 * 1024 and data.startswith(b"\xff\xd8\xff") and data.endswith(b"\xff\xd9")
        elif name == "Resources/AppIcon.png":
            valid_format = len(data) <= 2 * 1024 * 1024 and data.startswith(b"\x89PNG\r\n\x1a\n") and data.endswith(b"\x00\x00\x00\x00IEND\xaeB`\x82")
        elif name == "Resources/AppIcon.icns":
            valid_format = len(data) <= 2 * 1024 * 1024 and data.startswith(b"icns") and len(data) >= 8 and int.from_bytes(data[4:8], "big") == len(data)
        else:
            valid_format = False
        if not valid_format:
            problems.append("unexpected reviewed image format or size")
        if hashlib.sha256(data).hexdigest() != REVIEWED_IMAGES[name]:
            problems.append("image differs from visually reviewed synthetic asset")
        if any(term and term.casefold() in name.casefold() for term in deny_terms):
            problems.append("private review term")
        return problems
    allowed = name in ROOT_FILES or name == "docs/app-icon-prompt.txt" or (
        len(location.parts) > 1
        and location.suffix in DIRECTORY_SUFFIXES.get(location.parts[0], set())
        and not any(part.startswith(".") for part in location.parts[1:])
    )
    if not allowed:
        problems.append("file outside the source-only publication allowlist")
    if len(data) > 512 * 1024:
        problems.append("unexpectedly large source file")
    if b"\x00" in data or data.startswith(b"SQLite format 3"):
        problems.append("binary or database content")
        return problems
    try:
        content = data.decode("utf-8")
    except UnicodeDecodeError:
        return problems + ["non-UTF-8 content"]
    for label, pattern in PATTERNS.items():
        if pattern.search(content):
            problems.append(label)
    folded = content.casefold()
    if any(term and (term.casefold() in folded or term.casefold() in name.casefold()) for term in deny_terms):
        problems.append("private review term")
    return problems


def check_index(root, deny_terms=()):
    entries = subprocess.check_output(["git", "ls-files", "--stage", "-z"], cwd=root).split(b"\0")
    failures = []
    count = 0
    for entry in entries:
        if not entry:
            continue
        metadata, raw_name = entry.split(b"\t", 1)
        mode, object_id, stage = metadata.decode("ascii").split()
        name = raw_name.decode("utf-8", errors="replace")
        if stage != "0":
            failures.append((name, ["unresolved index conflict"]))
            continue
        if mode not in {"100644", "100755"}:
            failures.append((name, ["symlink, submodule, or unsupported file mode"]))
            continue
        data = subprocess.check_output(["git", "cat-file", "blob", object_id], cwd=root)
        problems = check_blob(name, mode, data, deny_terms)
        count += 1
        if problems:
            failures.append((name, problems))
    if not count:
        failures.append(("<index>", ["no indexed source files; stage the intended files first"]))
    return count, failures


def main():
    parser = argparse.ArgumentParser(description="Check exact Git-index contents before public source publication. No file contents are printed.")
    parser.add_argument("--deny-term", action="append", default=[], help="Additional private term to reject without echoing its value")
    arguments = parser.parse_args()
    root = pathlib.Path(__file__).resolve().parent.parent
    count, failures = check_index(root, arguments.deny_term)
    if failures:
        for name, problems in failures:
            print(f"BLOCKED {name!r}: {', '.join(problems)}", file=sys.stderr)
        return 1
    print(f"Publication check passed for {count} indexed files. Manually review the staged diff; pattern checks and reviewed image hashes cannot prove data anonymity or legal compliance.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
