"""
pytest configuration for yasdisk integration tests
"""

import os
import pytest
import subprocess
import tempfile


def pytest_configure(config):
    """Configure pytest."""
    config.addinivalue_line("markers", "slow: marks tests as slow")


@pytest.fixture
def yasdisk_path():
    """Path to the yasdisk binary."""
    # Try to find yasdisk binary
    paths = [
        os.path.join(os.path.dirname(__file__), "..", "..", "build", "yasdisk"),
        os.path.join(os.path.dirname(__file__), "..", "..", "yasdisk"),
    ]
    for path in paths:
        if os.path.exists(path):
            return os.path.abspath(path)
    pytest.skip("yasdisk binary not found")


@pytest.fixture
def temp_disk():
    """Create a temporary disk image file."""
    with tempfile.NamedTemporaryFile(delete=False, suffix=".img") as f:
        # Create 10MB disk image
        f.write(b'\x00' * (10 * 1024 * 1024))
        path = f.name

    yield path

    # Cleanup
    if os.path.exists(path):
        os.unlink(path)


@pytest.fixture
def yasdisk_list(yasdisk_path):
    """Helper to list partitions on a device."""
    def _list(device):
        result = subprocess.run(
            [yasdisk_path, "-l", device],
            capture_output=True,
            text=True
        )
        return result
    return _list


@pytest.fixture
def yasdisk_new(yasdisk_path):
    """Helper to create new partition table."""
    def _new(device):
        result = subprocess.run(
            [yasdisk_path, "-n", device],
            input="yes\n",
            capture_output=True,
            text=True
        )
        return result
    return _new
