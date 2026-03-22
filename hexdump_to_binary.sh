#!/bin/bash
# Converts hexdump from xxd format back to binary (supports little-endian 2-byte groups)
# Usage: ./hexdump_to_binary.sh <input_hexdump.txt> <output_binary>

if [ $# -lt 2 ]; then
    echo "Usage: $0 <input_hexdump.txt> <output_binary> [--little-endian]"
    echo "  --little-endian  Swap byte pairs in each 2-byte group (for little-endian dumps)"
    exit 1
fi

INPUT_FILE="$1"
OUTPUT_FILE="$2"
LITTLE_ENDIAN=false

if [ "$3" == "--little-endian" ]; then
    LITTLE_ENDIAN=true
fi

if [ ! -f "$INPUT_FILE" ]; then
    echo "Error: Input file '$INPUT_FILE' not found"
    exit 1
fi

if [ "$LITTLE_ENDIAN" == true ]; then
    # For little-endian: swap bytes in each 2-byte group
    # e.g., "4159" -> "5941", "7865" -> "6578"
    # xxd format: "0000000 4159 4646 0101 0100..."
    awk '
    /^[0-9a-fA-F]+ / {
        # Remove address prefix (first 7 chars: 6 hex digits + space)
        line = substr($0, 8)
        # Remove trailing ASCII representation (starts with "  ")
        sub(/  .*/, "", line)
        gsub(/ /, "", line)
        
        # Process each 4-char (2-byte) group
        for (i = 1; i <= length(line); i += 4) {
            group = substr(line, i, 4)
            if (length(group) == 4) {
                # Swap byte order: ABCD -> CDAB
                printf "%s%s", substr(group, 3, 2), substr(group, 1, 2)
            } else if (length(group) == 2) {
                printf "%s", group
            }
        }
    }
    ' "$INPUT_FILE" | xxd -r -p > "$OUTPUT_FILE"
else
    # Standard conversion
    xxd -r "$INPUT_FILE" "$OUTPUT_FILE"
fi

echo "Converted '$INPUT_FILE' -> '$OUTPUT_FILE'${LITTLE_ENDIAN:+ (little-endian)}"
