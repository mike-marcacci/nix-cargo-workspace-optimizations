# Nix + Cargo Workspace Optimizations

This repository demonstrates optimization patterns for building Rust workspaces with Nix, using [crane](https://github.com/ipetkov/crane) and [fenix](https://github.com/nix-community/fenix).

See [the corresponding blog post](https://www.m6i.tech/blog/optimizing-nix-builds-for-cargo-workspaces/) for a more thorough discussion.

## Workspace Structure

```
crates/
├── pkg-a/  (lib)   deps: once_cell, either
├── pkg-b/  (bin)   deps: pkg-a, once_cell
└── pkg-c/  (bin)   deps: pkg-a, itoa
pkg-d/      (bin)   deps: arrayvec
```

This structure demonstrates:
- **Parent/child**: `pkg-b` and `pkg-c` depend on `pkg-a`
- **Siblings**: `pkg-b` and `pkg-c` are independent of each other
- **Isolated**: `pkg-d` has no workspace dependencies

## Optimization Patterns

### 1. Source Isolation

**Problem**: A naive flake rebuilds all packages when any source file changes.

**Solution**: Filter source inputs per-package to only include relevant crates.

```nix
{
mkFilteredSrc = crates:
  pkgs.lib.cleanSourceWith {
    src = ./.;
    filter = path: type:
      # Exclude crate directories not in our set
      if isIrrelevantCrate then false
      else craneLib.filterCargoSources path type;
  };
}
```

**Result**: Changing `pkg-c/src/main.rs` does not invalidate `pkg-b`'s cache.

### 2. Dependency Auto-Discovery

**Problem**: Manually maintaining a dependency graph duplicates information from Cargo.toml.

**Solution**: Parse Cargo.toml files at Nix evaluation time.

```nix
{
getWorkspaceDeps = pname:
  let
    cargoToml = builtins.fromTOML (builtins.readFile ./crates/${pname}/Cargo.toml);
    deps = cargoToml.dependencies or { };
    workspaceDeps = pkgs.lib.filterAttrs (
      name: spec: builtins.isAttrs spec && spec ? path
    ) deps;
  in
  builtins.attrNames workspaceDeps;
}
```

**Result**: Adding a workspace dependency in Cargo.toml automatically updates the Nix build.

### 3. Per-Package External Dependencies

**Problem**: Shared `cargoArtifacts` compiles all external dependencies for every package.

**Solution**: Create per-package dependency derivations using `cargoExtraArgs`.

```nix
{
mkPackageDeps = pname:
  craneLib.buildDepsOnly {
    src = filteredSrc;
    cargoExtraArgs = "-p ${pname}";  # Only build deps for this package
  };
}
```

**Result**: Building `pkg-d` only compiles `arrayvec`, not `once_cell`/`either`/`itoa`.

## Cache Behavior

| Scenario | Rebuild? |
|----------|----------|
| Rebuild `pkg-d` without changes | No (cache hit) |
| Rebuild `pkg-d` after modifying `pkg-a` | No (no dependency) |
| Rebuild `pkg-b` after modifying `pkg-a` | Yes (dependency exists) |
| Rebuild `pkg-b` after modifying `pkg-c` | No (siblings independent) |

## Usage

```bash
# Build specific package
nix build .#pkg-b

# Build all packages
nix build

# Run all checks (clippy, tests, fmt)
nix flake check

# Run the optimization test suite
./scripts/test-nix-cache.sh

# Enter dev shell
nix develop
```

## Tradeoffs

| Optimization | Benefit | Cost |
|--------------|---------|------|
| Source isolation | Granular rebuilds | More complex filter logic |
| Per-package deps | Minimal compilation | More derivations to cache |
| Auto-discovery | Single source of truth | Evaluation-time file reads |

For small workspaces with overlapping dependencies, shared `cargoArtifacts` may be simpler and equally efficient. These patterns become valuable as workspace size and dependency divergence increase.

### Import From Derivation (IFD)

The source isolation and auto-discovery patterns use [Import From Derivation](https://nix.dev/manual/nix/latest/language/import-from-derivation), meaning Nix must build derivations during evaluation. This causes `nix flake show` to display:

```
omitted due to use of import from derivation
```

**Practical impact:**
- `nix flake show` and `nix flake check --dry-run` require `--allow-import-from-derivation`
- First evaluation is slower (subsequent evaluations use cached results)
- Hydra CI disables IFD by default

**What still works normally:** `nix build`, `nix develop`, `nix flake check`, binary caches.

The alternative — code generation tools like `crate2nix` or manual sync scripts — avoids IFD but introduces a second source of truth that can drift from Cargo.toml. For internal projects, IFD is typically an acceptable tradeoff.
