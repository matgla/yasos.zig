"""
Basic integration tests for yasdisk
"""

import os
import subprocess
import struct

import pytest


class TestListCommand:
    """Tests for the -l (list) command."""

    def test_list_empty_disk(self, temp_disk, yasdisk_path):
        """Test listing partitions on empty disk."""
        result = subprocess.run(
            [yasdisk_path, "-l", temp_disk],
            capture_output=True,
            text=True
        )
        assert result.returncode == 0
        assert "Disk:" in result.stdout
        assert temp_disk in result.stdout
        assert "Empty" in result.stdout

    def test_list_shows_device_info(self, temp_disk, yasdisk_path):
        """Test that device info is displayed."""
        result = subprocess.run(
            [yasdisk_path, "-l", temp_disk],
            capture_output=True,
            text=True
        )
        assert result.returncode == 0
        assert "Size:" in result.stdout
        assert "Sector size:" in result.stdout
        assert "10.00 MB" in result.stdout or "10485760" in result.stdout

    def test_list_invalid_device(self, yasdisk_path):
        """Test listing non-existent device."""
        result = subprocess.run(
            [yasdisk_path, "-l", "/nonexistent/device"],
            capture_output=True,
            text=True
        )
        assert result.returncode != 0
        assert "does not exist" in result.stderr or "Cannot open" in result.stderr


class TestNewCommand:
    """Tests for the -n (new) command."""

    def test_new_partition_table(self, temp_disk, yasdisk_path):
        """Test creating new partition table."""
        result = subprocess.run(
            [yasdisk_path, "-n", temp_disk],
            input="yes\n",
            capture_output=True,
            text=True
        )
        assert result.returncode == 0
        assert "New partition table created" in result.stdout

        # Verify MBR signature was written
        with open(temp_disk, 'rb') as f:
            f.seek(510)
            sig = f.read(2)
            assert sig == b'\x55\xAA'

    def test_new_requires_confirmation(self, temp_disk, yasdisk_path):
        """Test that new command requires 'yes' confirmation."""
        result = subprocess.run(
            [yasdisk_path, "-n", temp_disk],
            input="no\n",
            capture_output=True,
            text=True
        )
        assert result.returncode != 0
        assert "Aborted" in result.stdout

    def test_new_after_new(self, temp_disk, yasdisk_path):
        """Test creating new partition table twice."""
        # First new
        subprocess.run(
            [yasdisk_path, "-n", temp_disk],
            input="yes\n",
            capture_output=True,
            text=True
        )

        # Second new should also work
        result = subprocess.run(
            [yasdisk_path, "-n", temp_disk],
            input="yes\n",
            capture_output=True,
            text=True
        )
        assert result.returncode == 0


class TestMBRStructure:
    """Tests verifying MBR structure is correct."""

    def test_mbr_signature_location(self, temp_disk, yasdisk_path):
        """Test that MBR signature is at correct offset."""
        subprocess.run(
            [yasdisk_path, "-n", temp_disk],
            input="yes\n",
            capture_output=True,
            text=True
        )

        with open(temp_disk, 'rb') as f:
            data = f.read(512)

        # Signature at offset 510-511
        assert data[510] == 0x55
        assert data[511] == 0xAA

    def test_partition_table_offset(self, temp_disk, yasdisk_path):
        """Test that partition table starts at offset 446."""
        subprocess.run(
            [yasdisk_path, "-n", temp_disk],
            input="yes\n",
            capture_output=True,
            text=True
        )

        with open(temp_disk, 'rb') as f:
            data = f.read(512)

        # Boot code should be zeros (bytes 0-445)
        assert data[0:446] == b'\x00' * 446

        # Partition table starts at 446 (4 entries * 16 bytes = 64 bytes)
        # All entries should be empty (type = 0x00)
        for i in range(4):
            entry_offset = 446 + i * 16
            partition_type = data[entry_offset + 4]
            assert partition_type == 0x00


class TestPartitionManipulation:
    """Tests for partition creation and modification."""

    def create_partition_via_mbr_write(self, disk_path, index, start, count, ptype):
        """Helper to create a partition by directly writing MBR."""
        with open(disk_path, 'r+b') as f:
            # Read current MBR
            f.seek(0)
            mbr = bytearray(f.read(512))

            # Set partition entry
            entry_offset = 446 + index * 16

            # Boot flag (1 byte)
            mbr[entry_offset] = 0x00
            # CHS start (3 bytes) - simplified
            mbr[entry_offset + 1] = 0x00
            mbr[entry_offset + 2] = 0x01
            mbr[entry_offset + 3] = 0x00
            # Type (1 byte)
            mbr[entry_offset + 4] = ptype
            # CHS end (3 bytes) - simplified
            mbr[entry_offset + 5] = 0xFF
            mbr[entry_offset + 6] = 0xFF
            mbr[entry_offset + 7] = 0xFF
            # LBA start (4 bytes, little endian)
            mbr[entry_offset + 8:entry_offset + 12] = struct.pack('<I', start)
            # Sector count (4 bytes, little endian)
            mbr[entry_offset + 12:entry_offset + 16] = struct.pack('<I', count)

            # Write back
            f.seek(0)
            f.write(mbr)

    def test_list_shows_created_partition(self, temp_disk, yasdisk_path):
        """Test that created partition is shown in list."""
        # Create new MBR first
        subprocess.run(
            [yasdisk_path, "-n", temp_disk],
            input="yes\n",
            capture_output=True,
            text=True
        )

        # Create a Linux partition
        self.create_partition_via_mbr_write(temp_disk, 0, 2048, 4096, 0x83)

        # List should show the partition
        result = subprocess.run(
            [yasdisk_path, "-l", temp_disk],
            capture_output=True,
            text=True
        )
        assert result.returncode == 0
        assert "Linux" in result.stdout or "0x83" in result.stdout
