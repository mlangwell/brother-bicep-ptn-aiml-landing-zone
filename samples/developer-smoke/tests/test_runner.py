"""The CI entry point must fail when pytest did not execute any tests."""

import os
import subprocess
import sys
from pathlib import Path

import pytest


RUNNER = Path(__file__).resolve().parents[1] / "Test-Smoke.ps1"


@pytest.mark.parametrize(
    ("options", "expected_exit"),
    [("-k p4_selection_with_no_matching_test_52c9", 5), ("--collect-only", 1)],
    ids=["empty-selection", "collection-only"],
)
def test_runner_rejects_zero_execution(tmp_path, options, expected_exit):
    assert RUNNER.is_file(), "The sample test entry point is missing"
    environment = dict(os.environ, PYTEST_ADDOPTS=options)
    result = subprocess.run(
        [
            "pwsh",
            "-NoProfile",
            "-NonInteractive",
            "-File",
            str(RUNNER),
            "-PythonExecutable",
            sys.executable,
        ],
        cwd=tmp_path,
        env=environment,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        encoding="utf-8",
        timeout=60,
        check=False,
    )
    assert result.returncode == expected_exit, result.stdout
    assert "SMOKE TESTS PASSED" not in result.stdout
