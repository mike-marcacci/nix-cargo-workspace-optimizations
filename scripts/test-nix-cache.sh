#!/usr/bin/env bash
set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

cd "$REPO_ROOT"

# Ensure we have a clean git state for the source files we'll modify
ensure_clean() {
    git checkout -- crates/*/src/*.rs 2>/dev/null || true
}

# Modify a package's source by appending a unique comment
modify_source() {
    local pkg="$1"
    local src_file="crates/${pkg}/src/lib.rs"
    if [[ ! -f "$src_file" ]]; then
        src_file="crates/${pkg}/src/main.rs"
    fi
    echo "// Modified at $(date +%s%N)" >> "$src_file"
}

# Check if a nix build would use cache (returns 0 if cache hit, 1 if rebuild needed)
is_cached() {
    local pkg="$1"
    local output
    # --dry-run shows what would be built; if nothing, it's cached
    # We look for "will be built" in the output
    output=$(nix build ".#${pkg}" --dry-run 2>&1) || true
    if echo "$output" | grep -q "will be built"; then
        return 1  # Not cached, will rebuild
    else
        return 0  # Cached
    fi
}

# Build a package (ensure it's in the cache)
build_pkg() {
    local pkg="$1"
    echo -n "  Building ${pkg}... "
    nix build ".#${pkg}" --no-link 2>/dev/null
    echo "done"
}

# Run a single test case
# Arguments: test_name build_pkg modify_pkg rebuild_pkg expect_cache
run_test() {
    local test_name="$1"
    local build_pkg="$2"
    local modify_pkg="$3"  # empty string means no modification
    local rebuild_pkg="$4"
    local expect_cache="$5"  # "hit" or "miss"

    echo -e "\n${YELLOW}Test: ${test_name}${NC}"
    echo "  Build: ${build_pkg}, Modify: ${modify_pkg:-none}, Rebuild: ${rebuild_pkg}, Expect: cache ${expect_cache}"

    # Ensure clean state
    ensure_clean

    # Step 1: Initial build
    build_pkg "$build_pkg"

    # Step 2: Modify source if specified
    if [[ -n "$modify_pkg" ]]; then
        echo "  Modifying ${modify_pkg}..."
        modify_source "$modify_pkg"
        git add -A  # Stage for nix to see
    fi

    # Step 3: Check if rebuild would use cache
    echo -n "  Checking cache for ${rebuild_pkg}... "
    if is_cached "$rebuild_pkg"; then
        actual="hit"
    else
        actual="miss"
    fi
    echo "$actual"

    # Step 4: Restore clean state
    ensure_clean
    git add -A

    # Step 5: Report result
    if [[ "$actual" == "$expect_cache" ]]; then
        echo -e "  ${GREEN}PASS${NC}"
        return 0
    else
        echo -e "  ${RED}FAIL${NC} (expected ${expect_cache}, got ${actual})"
        return 1
    fi
}

# Main test suite
main() {
    echo "=== Nix Cache Optimization Tests ==="
    echo "Repository: $REPO_ROOT"

    local passed=0
    local failed=0

    # Ensure clean starting state
    ensure_clean
    git add -A

    # Test 1: pkg-d rebuild without changes should use cache
    if run_test "1: No-change rebuild" "pkg-d" "" "pkg-d" "hit"; then
        ((passed++))
    else
        ((failed++))
    fi

    # Test 2: pkg-d after pkg-a change should use cache (no dependency)
    if run_test "2: Unrelated change (pkg-d after pkg-a mod)" "pkg-d" "pkg-a" "pkg-d" "hit"; then
        ((passed++))
    else
        ((failed++))
    fi

    # Test 3: pkg-b after pkg-a change must recompile (dependency exists)
    if run_test "3: Dependency change (pkg-b after pkg-a mod)" "pkg-b" "pkg-a" "pkg-b" "miss"; then
        ((passed++))
    else
        ((failed++))
    fi

    # Test 4: pkg-b after pkg-c change should use cache (no dependency)
    if run_test "4: Sibling change (pkg-b after pkg-c mod)" "pkg-b" "pkg-c" "pkg-b" "hit"; then
        ((passed++))
    else
        ((failed++))
    fi

    # Test 5: pkg-b after pkg-c change (pkg-a built first) should use cache
    if run_test "5: Unrelated sibling (pkg-a then pkg-b after pkg-c mod)" "pkg-a" "pkg-c" "pkg-b" "hit"; then
        ((passed++))
    else
        ((failed++))
    fi

    # Summary
    echo ""
    echo "=== Summary ==="
    echo -e "Passed: ${GREEN}${passed}${NC}"
    echo -e "Failed: ${RED}${failed}${NC}"

    if [[ $failed -eq 0 ]]; then
        echo -e "\n${GREEN}All tests passed!${NC}"
        exit 0
    else
        echo -e "\n${RED}Some tests failed.${NC}"
        exit 1
    fi
}

main "$@"
