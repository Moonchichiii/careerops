from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def test_python_tooling_has_one_configuration_home() -> None:
    forbidden_names = {
        "pytest.ini",
        ".pytest.ini",
        "mypy.ini",
        ".mypy.ini",
        "ruff.toml",
        ".ruff.toml",
        "setup.cfg",
        "requirements.txt",
        "requirements-dev.txt",
        "Pipfile",
        "poetry.lock",
    }

    present = sorted(
        path.relative_to(ROOT).as_posix()
        for path in ROOT.rglob("*")
        if path.is_file() and path.name in forbidden_names
    )

    assert present == []
    assert (ROOT / "pyproject.toml").is_file()


def test_django_settings_structure_is_stable() -> None:
    settings_dir = ROOT / "config" / "settings"
    expected = {"__init__.py", "base.py", "local.py", "tests.py", "production.py"}
    actual = {path.name for path in settings_dir.iterdir() if path.is_file()}

    assert actual == expected


def test_conceptual_erd_has_one_authoritative_home() -> None:
    dbml_files = sorted(ROOT.glob("docs/**/*.dbml"))

    assert dbml_files == [ROOT / "docs" / "architecture" / "erd" / "careerops.dbml"]


def test_repository_does_not_use_pip_install_commands() -> None:
    command = re.compile(r"\b(?:python\s+-m\s+)?pip\s+install\b", re.IGNORECASE)
    text_suffixes = {".md", ".py", ".toml", ".yaml", ".yml", ".sh", ".ps1"}
    violations: list[str] = []

    for path in ROOT.rglob("*"):
        if not path.is_file() or path.suffix not in text_suffixes:
            continue
        if any(part.startswith(".") and part not in {".github"} for part in path.parts):
            continue

        content = path.read_text(encoding="utf-8")
        if command.search(content):
            violations.append(path.relative_to(ROOT).as_posix())

    assert violations == []


def test_third_party_github_actions_are_pinned_to_commit_shas() -> None:
    uses_pattern = re.compile(r"^\s*uses:\s*([^\s#]+)", re.MULTILINE)
    sha_pattern = re.compile(r"^[^@]+@[0-9a-f]{40}$")
    violations: list[str] = []

    for workflow in sorted((ROOT / ".github" / "workflows").glob("*.yml")):
        for reference in uses_pattern.findall(workflow.read_text(encoding="utf-8")):
            if reference.startswith("./"):
                continue
            if not sha_pattern.fullmatch(reference):
                violations.append(f"{workflow.name}: {reference}")

    assert violations == []
