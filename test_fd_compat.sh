#!/bin/bash
#
# Extensive test suite comparing nom-fd with fd
#
# This script runs various fd commands and compares output between
# the original fd and nom-fd to verify compatibility.
#

# Don't use set -e as arithmetic operations may return non-zero

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Counters
PASS=0
FAIL=0
SKIP=0

# Get absolute path to nom-fd from script location
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NOM_FD="$SCRIPT_DIR/zig-out/bin/nom-fd"
FD="fd"

# Create test directory structure
setup_test_dir() {
    TEST_DIR=$(mktemp -d)
    trap "rm -rf $TEST_DIR" EXIT

    # Create directory structure
    mkdir -p "$TEST_DIR/src/lib"
    mkdir -p "$TEST_DIR/src/bin"
    mkdir -p "$TEST_DIR/tests"
    mkdir -p "$TEST_DIR/docs"
    mkdir -p "$TEST_DIR/.hidden_dir"
    mkdir -p "$TEST_DIR/empty_dir"
    mkdir -p "$TEST_DIR/deep/nested/path/to/files"

    # Create files
    touch "$TEST_DIR/README.md"
    touch "$TEST_DIR/Makefile"
    touch "$TEST_DIR/main.zig"
    touch "$TEST_DIR/src/lib.zig"
    touch "$TEST_DIR/src/utils.zig"
    touch "$TEST_DIR/src/lib/core.zig"
    touch "$TEST_DIR/src/lib/helpers.zig"
    touch "$TEST_DIR/src/bin/main.zig"
    touch "$TEST_DIR/tests/test_basic.zig"
    touch "$TEST_DIR/tests/test_advanced.zig"
    touch "$TEST_DIR/docs/api.md"
    touch "$TEST_DIR/docs/guide.txt"
    touch "$TEST_DIR/.hidden_file"
    touch "$TEST_DIR/.hidden_dir/secret.txt"
    touch "$TEST_DIR/deep/nested/path/to/files/deep.zig"
    touch "$TEST_DIR/file.rs"
    touch "$TEST_DIR/script.py"
    touch "$TEST_DIR/config.json"
    touch "$TEST_DIR/data.xml"

    # Create files with different sizes
    echo "small" > "$TEST_DIR/small.txt"
    head -c 10000 /dev/zero > "$TEST_DIR/medium.bin" 2>/dev/null || dd if=/dev/zero of="$TEST_DIR/medium.bin" bs=1 count=10000 2>/dev/null
    head -c 100000 /dev/zero > "$TEST_DIR/large.bin" 2>/dev/null || dd if=/dev/zero of="$TEST_DIR/large.bin" bs=1 count=100000 2>/dev/null

    # Create gitignore
    echo "*.bin" > "$TEST_DIR/.gitignore"
    echo "empty_dir/" >> "$TEST_DIR/.gitignore"

    # Initialize git repo
    (cd "$TEST_DIR" && git init -q)
}

# Normalize output by removing trailing slashes on directories
normalize_output() {
    sed 's|/$||g' | sort
}

# Run a test comparing fd and nom-fd output
run_test() {
    local name="$1"
    local fd_args="$2"
    local nom_fd_args="${3:-$2}"  # Default to same args if not specified

    # Run both commands and capture output (normalize trailing slashes) with timeout
    local fd_output nom_fd_output
    fd_output=$(cd "$TEST_DIR" && timeout 5 $FD $fd_args 2>/dev/null | normalize_output || echo "__ERROR__")
    nom_fd_output=$(cd "$TEST_DIR" && timeout 5 $NOM_FD $nom_fd_args 2>/dev/null | normalize_output || echo "__ERROR__")

    if [ "$fd_output" = "__ERROR__" ] && [ "$nom_fd_output" = "__ERROR__" ]; then
        echo -e "${YELLOW}SKIP${NC}: $name (both errored)"
        SKIP=$((SKIP + 1))
        return
    fi

    if [ "$fd_output" = "$nom_fd_output" ]; then
        echo -e "${GREEN}PASS${NC}: $name"
        PASS=$((PASS + 1))
    else
        echo -e "${RED}FAIL${NC}: $name"
        echo "  fd args: $fd_args"
        echo "  nom-fd args: $nom_fd_args"
        echo "  fd output:"
        echo "$fd_output" | sed 's/^/    /' | head -10
        echo "  nom-fd output:"
        echo "$nom_fd_output" | sed 's/^/    /' | head -10
        FAIL=$((FAIL + 1))
    fi
}

# Test with specific expected output
run_test_expect() {
    local name="$1"
    local args="$2"
    local expected="$3"

    local output
    output=$(cd "$TEST_DIR" && timeout 5 $NOM_FD $args 2>/dev/null | sort || echo "__ERROR__")

    if [ "$output" = "$expected" ]; then
        echo -e "${GREEN}PASS${NC}: $name"
        PASS=$((PASS + 1))
    else
        echo -e "${RED}FAIL${NC}: $name"
        echo "  args: $args"
        echo "  expected: $expected"
        echo "  got: $output"
        FAIL=$((FAIL + 1))
    fi
}

# Check if fd is available
if ! command -v fd &> /dev/null; then
    echo "Warning: fd not found, some comparison tests will be skipped"
    FD="false"
fi

# Check if nom-fd is built
if [ ! -f "$NOM_FD" ]; then
    echo "Building nom-fd..."
    zig build
fi

echo "======================================"
echo "nom-fd compatibility test suite"
echo "======================================"
echo

# Setup
echo "Setting up test directory..."
setup_test_dir
echo

# ============================================================
# Basic listing tests
# ============================================================
echo "--- Basic Listing ---"

run_test "List all files (no args)" "" ""

run_test "List all including hidden (-H)" "-H" "-H"

run_test "List files ignoring gitignore (-I)" "-I" "-I"

run_test "List all including hidden and ignored (-HI)" "-HI" "-H -I"

# ============================================================
# Pattern matching tests
# ============================================================
echo
echo "--- Pattern Matching ---"

run_test "Glob pattern (*.zig)" "-g '*.zig'" "-g '*.zig'"

run_test "Glob pattern (*.md)" "-g '*.md'" "-g '*.md'"

run_test "Partial name (main)" "main" "main"

run_test "Case insensitive pattern (README)" "-i readme" "-i readme"

run_test "Full path matching (-p)" "-p 'src/lib'" "-p 'src/lib'"

# ============================================================
# Type filtering tests
# ============================================================
echo
echo "--- Type Filtering ---"

run_test "Files only (-t f)" "-t f" "-t f"

run_test "Directories only (-t d)" "-t d" "-t d"

run_test "Combined types (-t f -t d)" "-t f -t d" "-t f -t d"

# ============================================================
# Extension filtering tests
# ============================================================
echo
echo "--- Extension Filtering ---"

run_test "Single extension (-e zig)" "-e zig" "-e zig"

run_test "Multiple extensions (-e zig -e md)" "-e zig -e md" "-e zig -e md"

run_test "Extension with type (-e zig -t f)" "-e zig -t f" "-e zig -t f"

# ============================================================
# Depth limiting tests
# ============================================================
echo
echo "--- Depth Limiting ---"

run_test "Max depth 1 (-d 1)" "-d 1" "-d 1"

run_test "Max depth 2 (-d 2)" "-d 2" "-d 2"

run_test "Min depth 1 (--min-depth 1)" "--min-depth 1" "--min-depth 1"

run_test "Depth range (--min-depth 1 -d 2)" "--min-depth 1 -d 2" "--min-depth 1 -d 2"

# ============================================================
# Exclusion tests
# ============================================================
echo
echo "--- Exclusion Patterns ---"

run_test "Exclude pattern (-E '*.md')" "-E '*.md'" "-E '*.md'"

run_test "Exclude directory (-E tests)" "-E tests" "-E tests"

run_test "Multiple exclusions (-E tests -E docs)" "-E tests -E docs" "-E tests -E docs"

# ============================================================
# Output format tests
# ============================================================
echo
echo "--- Output Format ---"

# Note: We test that -0 produces null-separated output
run_test "Print0 output format (-0)" "-0 -g '*.zig'" "-0 -g '*.zig'"

# ============================================================
# Search path tests
# ============================================================
echo
echo "--- Search Paths ---"

run_test "Search in subdirectory" "-g '*.zig' src" "-g '*.zig' src"

run_test "Search in multiple dirs" "-g '*.zig' src tests" "-g '*.zig' src tests"

# ============================================================
# Combined options tests
# ============================================================
echo
echo "--- Combined Options ---"

run_test "Files only, max depth 2, zig extension" "-t f -d 2 -e zig" "-t f -d 2 -e zig"

run_test "Hidden files with extension" "-H -e txt" "-H -e txt"

run_test "Pattern with type and extension" "'main' -t f -e zig" "'main' -t f -e zig"

# ============================================================
# Edge cases
# ============================================================
echo
echo "--- Edge Cases ---"

# Empty dir is gitignored, so skip this test or use -I
run_test "Search in empty_dir (gitignored)" "-I . empty_dir" "-I . empty_dir"

run_test "Deep nested files" "-g '*.zig' deep" "-g '*.zig' deep"

run_test "Nonexistent pattern" "'nonexistent_pattern_xyz'" "'nonexistent_pattern_xyz'"

# ============================================================
# Size filtering tests (if supported)
# ============================================================
echo
echo "--- Size Filtering ---"

# Note: fd uses -S for size, nom-fd should too
run_test "Size filter min (-S +1k)" "-S +1k" "-S +1k"

run_test "Size filter max (-S -1m)" "-S -1m" "-S -1m"

# ============================================================
# Results limiting tests
# ============================================================
echo
echo "--- Result Limiting ---"

# Note: nom-fd uses --max-results
nom_output=$(cd "$TEST_DIR" && timeout 5 $NOM_FD --max-results 3 2>/dev/null | wc -l | tr -d ' ')
if [ "$nom_output" = "3" ]; then
    echo -e "${GREEN}PASS${NC}: Max results limit (--max-results 3)"
    PASS=$((PASS + 1))
else
    echo -e "${RED}FAIL${NC}: Max results limit (--max-results 3), got $nom_output lines"
    FAIL=$((FAIL + 1))
fi

# ============================================================
# Summary
# ============================================================
echo
echo "======================================"
echo "Test Results"
echo "======================================"
echo -e "Passed: ${GREEN}$PASS${NC}"
echo -e "Failed: ${RED}$FAIL${NC}"
echo -e "Skipped: ${YELLOW}$SKIP${NC}"
echo

if [ $FAIL -eq 0 ]; then
    echo -e "${GREEN}All tests passed!${NC}"
    exit 0
else
    echo -e "${RED}Some tests failed.${NC}"
    exit 1
fi
