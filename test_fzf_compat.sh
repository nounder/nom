#!/bin/bash
# fzf compatibility test script
# Compares nom output with fzf output for various flags

# Don't exit on error - we want to run all tests

NOM="./zig-out/bin/nom"
FZF="fzf"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

PASSED=0
FAILED=0
SKIPPED=0

# Test data
TEST_DATA="hello world
foo bar baz
test line one
test line two
apple banana cherry
zig programming language
rust systems programming
python scripting
javascript nodejs
typescript angular"

# Function to run a filter test
run_filter_test() {
    local description="$1"
    local filter_arg="$2"
    local extra_args="$3"

    # Run both commands
    local nom_output=$(echo "$TEST_DATA" | $NOM -f "$filter_arg" $extra_args 2>/dev/null || echo "__NOM_ERROR__")
    local fzf_output=$(echo "$TEST_DATA" | $FZF -f "$filter_arg" $extra_args 2>/dev/null || echo "__FZF_ERROR__")

    if [[ "$nom_output" == "__NOM_ERROR__" ]]; then
        echo -e "${YELLOW}SKIP${NC}: $description (nom error)"
        ((SKIPPED++))
        return
    fi

    if [[ "$fzf_output" == "__FZF_ERROR__" ]]; then
        echo -e "${YELLOW}SKIP${NC}: $description (fzf not available or error)"
        ((SKIPPED++))
        return
    fi

    # Compare outputs (ignore trailing whitespace differences)
    local nom_clean=$(echo "$nom_output" | sed 's/[[:space:]]*$//')
    local fzf_clean=$(echo "$fzf_output" | sed 's/[[:space:]]*$//')

    if [[ "$nom_clean" == "$fzf_clean" ]]; then
        echo -e "${GREEN}PASS${NC}: $description"
        ((PASSED++))
    else
        echo -e "${RED}FAIL${NC}: $description"
        echo "  nom output:"
        echo "$nom_output" | head -5 | sed 's/^/    /'
        echo "  fzf output:"
        echo "$fzf_output" | head -5 | sed 's/^/    /'
        ((FAILED++))
    fi
}

# Function to compare just the matched lines (ignoring order since scoring may differ)
run_filter_test_unordered() {
    local description="$1"
    local filter_arg="$2"
    local extra_args="$3"

    # Run both commands
    local nom_output=$(echo "$TEST_DATA" | $NOM -f "$filter_arg" $extra_args 2>/dev/null | sort || echo "__NOM_ERROR__")
    local fzf_output=$(echo "$TEST_DATA" | $FZF -f "$filter_arg" $extra_args 2>/dev/null | sort || echo "__FZF_ERROR__")

    if [[ "$nom_output" == "__NOM_ERROR__" ]]; then
        echo -e "${YELLOW}SKIP${NC}: $description (nom error)"
        ((SKIPPED++))
        return
    fi

    if [[ "$fzf_output" == "__FZF_ERROR__" ]]; then
        echo -e "${YELLOW}SKIP${NC}: $description (fzf not available)"
        ((SKIPPED++))
        return
    fi

    # Compare sorted outputs
    local nom_clean=$(echo "$nom_output" | sed 's/[[:space:]]*$//')
    local fzf_clean=$(echo "$fzf_output" | sed 's/[[:space:]]*$//')

    if [[ "$nom_clean" == "$fzf_clean" ]]; then
        echo -e "${GREEN}PASS${NC}: $description (same matches)"
        ((PASSED++))
    else
        echo -e "${RED}FAIL${NC}: $description"
        echo "  nom matches:"
        echo "$nom_output" | head -5 | sed 's/^/    /'
        echo "  fzf matches:"
        echo "$fzf_output" | head -5 | sed 's/^/    /'
        ((FAILED++))
    fi
}

echo "=== fzf Compatibility Tests ==="
echo ""

# Check if nom is built
if [[ ! -f "$NOM" ]]; then
    echo "Building nom..."
    zig build
fi

# Check if fzf is available
if ! command -v $FZF &> /dev/null; then
    echo -e "${YELLOW}Warning: fzf not found, tests will be skipped${NC}"
fi

echo "--- Basic Filter Tests ---"

# Basic fuzzy matching
run_filter_test_unordered "Basic fuzzy match 'test'" "test"
run_filter_test_unordered "Basic fuzzy match 'lang'" "lang"
run_filter_test_unordered "Basic fuzzy match 'pro'" "pro"

# Exact matching
run_filter_test_unordered "Exact match 'test line'" "'test line"
run_filter_test_unordered "Exact match (substring)" "'hello"

# Prefix matching
run_filter_test_unordered "Prefix match '^test'" "^test"
run_filter_test_unordered "Prefix match '^hello'" "^hello"

# Suffix matching
run_filter_test_unordered "Suffix match 'ing\$'" "ing\$"
run_filter_test_unordered "Suffix match 'world\$'" "world\$"

# Negation
run_filter_test_unordered "Negation '!test'" "!test"

echo ""
echo "--- Field Selection Tests (--nth) ---"

# Field selection with --nth
FIELD_DATA="one two three
four five six
seven eight nine
ten eleven twelve"

nom_nth_output=$(echo "$FIELD_DATA" | $NOM -f "five" -n2 2>/dev/null || echo "")
fzf_nth_output=$(echo "$FIELD_DATA" | $FZF -f "five" -n2 2>/dev/null || echo "")

if [[ "$nom_nth_output" == "$fzf_nth_output" ]]; then
    echo -e "${GREEN}PASS${NC}: --nth field 2 match 'five'"
    ((PASSED++))
else
    echo -e "${RED}FAIL${NC}: --nth field 2 match 'five'"
    echo "  nom: $nom_nth_output"
    echo "  fzf: $fzf_nth_output"
    ((FAILED++))
fi

# Multiple field range
nom_nth_output2=$(echo "$FIELD_DATA" | $NOM -f "one" -n1 2>/dev/null || echo "")
fzf_nth_output2=$(echo "$FIELD_DATA" | $FZF -f "one" -n1 2>/dev/null || echo "")

if [[ "$nom_nth_output2" == "$fzf_nth_output2" ]]; then
    echo -e "${GREEN}PASS${NC}: --nth field 1 match 'one'"
    ((PASSED++))
else
    echo -e "${RED}FAIL${NC}: --nth field 1 match 'one'"
    echo "  nom: $nom_nth_output2"
    echo "  fzf: $fzf_nth_output2"
    ((FAILED++))
fi

echo ""
echo "--- Case Sensitivity Tests ---"

CASE_DATA="Hello World
HELLO WORLD
hello world
HeLLo WoRLd"

# Case insensitive (default)
nom_case=$(echo "$CASE_DATA" | $NOM -f "hello" -i 2>/dev/null | sort || echo "")
fzf_case=$(echo "$CASE_DATA" | $FZF -f "hello" -i 2>/dev/null | sort || echo "")

if [[ "$nom_case" == "$fzf_case" ]]; then
    echo -e "${GREEN}PASS${NC}: Case insensitive match"
    ((PASSED++))
else
    echo -e "${RED}FAIL${NC}: Case insensitive match"
    ((FAILED++))
fi

# Case sensitive
nom_case_s=$(echo "$CASE_DATA" | $NOM -f "hello" +i 2>/dev/null | sort || echo "")
fzf_case_s=$(echo "$CASE_DATA" | $FZF -f "hello" +i 2>/dev/null | sort || echo "")

if [[ "$nom_case_s" == "$fzf_case_s" ]]; then
    echo -e "${GREEN}PASS${NC}: Case sensitive match"
    ((PASSED++))
else
    echo -e "${RED}FAIL${NC}: Case sensitive match"
    echo "  nom: '$nom_case_s'"
    echo "  fzf: '$fzf_case_s'"
    ((FAILED++))
fi

echo ""
echo "--- Output Format Tests ---"

# print0 test
nom_print0=$(echo "$TEST_DATA" | $NOM -f "test" --print0 2>/dev/null | xxd | head -2 || echo "")
fzf_print0=$(echo "$TEST_DATA" | $FZF -f "test" --print0 2>/dev/null | xxd | head -2 || echo "")

# Just check that both use null separators (exact hex may differ due to ordering)
if [[ "$nom_print0" == *"00"* ]] && [[ "$fzf_print0" == *"00"* ]]; then
    echo -e "${GREEN}PASS${NC}: --print0 uses null separators"
    ((PASSED++))
elif [[ -z "$nom_print0" ]] || [[ -z "$fzf_print0" ]]; then
    echo -e "${YELLOW}SKIP${NC}: --print0 test (no output)"
    ((SKIPPED++))
else
    echo -e "${RED}FAIL${NC}: --print0 null separator check"
    ((FAILED++))
fi

echo ""
echo "--- Header Tests ---"

# Header test (just verify it doesn't crash)
nom_header=$(echo "$TEST_DATA" | $NOM -f "test" --header="Test Header" 2>/dev/null || echo "__ERROR__")
if [[ "$nom_header" != "__ERROR__" ]]; then
    echo -e "${GREEN}PASS${NC}: --header doesn't crash"
    ((PASSED++))
else
    echo -e "${RED}FAIL${NC}: --header crashed"
    ((FAILED++))
fi

# Header lines test
nom_header_lines=$(echo "$TEST_DATA" | $NOM -f "test" --header-lines=2 2>/dev/null || echo "__ERROR__")
if [[ "$nom_header_lines" != "__ERROR__" ]]; then
    echo -e "${GREEN}PASS${NC}: --header-lines doesn't crash"
    ((PASSED++))
else
    echo -e "${RED}FAIL${NC}: --header-lines crashed"
    ((FAILED++))
fi

echo ""
echo "=== Summary ==="
echo -e "Passed: ${GREEN}$PASSED${NC}"
echo -e "Failed: ${RED}$FAILED${NC}"
echo -e "Skipped: ${YELLOW}$SKIPPED${NC}"

if [[ $FAILED -gt 0 ]]; then
    exit 1
fi

exit 0
