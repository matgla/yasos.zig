from __future__ import annotations

import re
import shutil
from pathlib import Path
from typing import Any


def sanitize_artifact_name(value: str) -> str:
    sanitized = re.sub(r"[^A-Za-z0-9._-]+", "_", value).strip("._")
    return sanitized or "artifact"


def failed_logs_dir(logs_dir: Path) -> Path:
    return logs_dir / "failed"


def move_failed_target_logs(logs_dir: Path, target_log_paths: list[Path]) -> list[Path]:
    destination_dir = failed_logs_dir(logs_dir)
    destination_dir.mkdir(parents=True, exist_ok=True)

    moved_paths: list[Path] = []
    seen_paths: set[Path] = set()
    for target_log_path in target_log_paths:
        path = Path(target_log_path)
        if path in seen_paths:
            continue
        seen_paths.add(path)

        if destination_dir in path.parents:
            moved_paths.append(path)
            continue
        if not path.exists():
            continue

        destination = destination_dir / path.name
        shutil.move(str(path), str(destination))
        moved_paths.append(destination)

    return moved_paths


def write_failed_pytest_log(logs_dir: Path, nodeid: str, reports: list[Any]) -> Path:
    destination_dir = failed_logs_dir(logs_dir)
    destination_dir.mkdir(parents=True, exist_ok=True)
    artifact_path = destination_dir / f"{sanitize_artifact_name(nodeid)}_pytest.txt"

    lines = [f"nodeid: {nodeid}"]
    for index, report in enumerate(reports, start=1):
        lines.extend(
            [
                "",
                f"=== failure {index} ===",
                f"phase: {getattr(report, 'when', 'unknown')}",
                f"outcome: {getattr(report, 'outcome', 'failed')}",
            ]
        )

        longrepr = str(getattr(report, "longreprtext", "") or "").rstrip()
        if longrepr:
            lines.extend(["", longrepr])

        for section_name, section_content in getattr(report, "sections", ()) or ():
            content = str(section_content).rstrip()
            if not content:
                continue
            lines.extend(["", f"--- {section_name} ---", content])

    artifact_path.write_text("\n".join(lines).rstrip() + "\n", encoding="utf-8")
    return artifact_path
