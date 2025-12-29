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

# Check if a crate dependency is in the vendored deps for a package
# This checks what's actually in the cargoArtifacts the package uses
# Returns 0 if dep IS in vendor, 1 if not
dep_in_vendor() {
    local pkg="$1"
    local dep="$2"
    local temp_dir

    # Build the package to ensure deps are built
    nix build ".#${pkg}" --no-link 2>/dev/null

    # Find the deps derivation and realize it
    local deps_drv
    deps_drv=$(nix path-info --derivation ".#${pkg}" -r 2>/dev/null | grep "deps-0.1.0.drv" | head -1)

    if [[ -z "$deps_drv" ]]; then
        echo "Warning: Could not find deps derivation" >&2
        return 1
    fi

    # Realize the derivation to get the output path
    local deps_out
    deps_out=$(nix-store --realize "$deps_drv" 2>/dev/null)

    if [[ -z "$deps_out" || ! -f "$deps_out/target.tar.zst" ]]; then
        echo "Warning: Could not find deps output" >&2
        return 1
    fi

    # Extract and check for the dep
    temp_dir=$(mktemp -d)
    zstd -d -c "$deps_out/target.tar.zst" | tar -xf - -C "$temp_dir" 2>/dev/null

    # Check if the dep exists in the target directory
    if ls "$temp_dir"/release/deps/*"${dep}"* 2>/dev/null | grep -q .; then
        rm -rf "$temp_dir"
        return 0  # Dep IS in vendor
    else
        rm -rf "$temp_dir"
        return 1  # Dep is NOT in vendor
    fi
}

# Run a dependency isolation test
# Arguments: test_name pkg dep expect_in_deps ("yes" or "no")
run_dep_test() {
    local test_name="$1"
    local pkg="$2"
    local dep="$3"
    local expect_in_deps="$4"  # "yes" or "no"

    echo -e "\n${YELLOW}Test: ${test_name}${NC}"
    echo "  Package: ${pkg}, Dependency: ${dep}, Expect in deps: ${expect_in_deps}"

    echo -n "  Checking deps for ${pkg}... "
    if dep_in_vendor "$pkg" "$dep"; then
        actual="yes"
    else
        actual="no"
    fi
    echo "dep ${dep} in deps: ${actual}"

    if [[ "$actual" == "$expect_in_deps" ]]; then
        echo -e "  ${GREEN}PASS${NC}"
        return 0
    else
        echo -e "  ${RED}FAIL${NC} (expected ${expect_in_deps}, got ${actual})"
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

    echo ""
    echo "--- Source Isolation Tests ---"

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

    echo ""
    echo "--- Dependency Isolation Tests ---"

    # Test 6: pkg-b closure should NOT include arrayvec (it doesn't need it)
    if run_dep_test "6: pkg-b excludes arrayvec" "pkg-b" "arrayvec" "no"; then
        ((passed++))
    else
        ((failed++))
    fi

    # Test 7: pkg-b closure SHOULD include once_cell (it needs it directly)
    if run_dep_test "8: pkg-b includes once_cell" "pkg-b" "once_cell" "yes"; then
        ((passed++))
    else
        ((failed++))
    fi

    # Test 8: pkg-b closure SHOULD include either (it needs it transitively)
    if run_dep_test "7: pkg-b includes either" "pkg-b" "either" "yes"; then
        ((passed++))
    else
        ((failed++))
    fi

    # Test 9: pkg-a closure should NOT include itoa (it doesn't need it)
    if run_dep_test "9: pkg-a excludes itoa" "pkg-a" "itoa" "no"; then
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
