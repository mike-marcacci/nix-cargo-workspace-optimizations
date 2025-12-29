{
  description = "Rust monorepo with Cargo workspace";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    fenix = {
      url = "github:nix-community/fenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    crane.url = "github:ipetkov/crane";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      self,
      nixpkgs,
      fenix,
      crane,
      flake-utils,
      ...
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        # Use toolchain from rust-toolchain.toml via fenix
        rustToolchain = fenix.packages.${system}.fromToolchainFile {
          file = ./rust-toolchain.toml;
          sha256 = "sha256-sqSWJDUxc+zaz1nBWMAJKTAGBuGWP25GCftIOlCEAtA=";
        };

        # Initialize crane with our toolchain
        craneLib = (crane.mkLib pkgs).overrideToolchain rustToolchain;

        # Parse workspace Cargo.toml to get member patterns
        workspaceCargoToml = builtins.fromTOML (builtins.readFile ./Cargo.toml);
        memberPatterns = workspaceCargoToml.workspace.members or [ ];

        # Expand member patterns (handles both explicit paths and globs like "crates/*")
        expandMemberPattern =
          pattern:
          let
            # Check if pattern ends with /*
            globMatch = builtins.match "(.+)/\\*" pattern;
          in
          if globMatch != null then
            # It's a glob pattern like "crates/*" - list the directory
            let
              baseDir = builtins.head globMatch;
            in
            map (name: "${baseDir}/${name}") (
              builtins.attrNames (
                pkgs.lib.filterAttrs (_: type: type == "directory") (builtins.readDir ./${baseDir})
              )
            )
          else
            # Explicit path
            [ pattern ];

        # Get all workspace member paths (e.g., ["crates/foo", "crates/bar"])
        workspaceMemberPaths = builtins.concatMap expandMemberPattern memberPatterns;

        # Map from crate name to its path
        cratePaths = builtins.listToAttrs (
          map (path: {
            name = builtins.baseNameOf path;
            value = path;
          }) workspaceMemberPaths
        );

        # List of crate names
        workspaceCrates = builtins.attrNames cratePaths;

        # Parse a crate's Cargo.toml and extract workspace dependencies
        # (dependencies with path = "../<crate>" pointing to sibling crates)
        getWorkspaceDeps =
          pname:
          let
            cratePath = cratePaths.${pname};
            cargoToml = builtins.fromTOML (builtins.readFile ./${cratePath}/Cargo.toml);
            deps = cargoToml.dependencies or { };
            # Filter to only path dependencies that point to workspace crates
            workspaceDeps = pkgs.lib.filterAttrs (
              name: spec: builtins.isAttrs spec && spec ? path && builtins.elem name workspaceCrates
            ) deps;
          in
          builtins.attrNames workspaceDeps;

        # Recursively resolve all transitive workspace dependencies
        getAllDeps =
          pname:
          let
            directDeps = getWorkspaceDeps pname;
            transitiveDeps = builtins.concatMap getAllDeps directDeps;
          in
          pkgs.lib.unique (directDeps ++ transitiveDeps);

        # Build the full dependency graph (auto-discovered from Cargo.toml files)
        packageDeps = builtins.listToAttrs (
          map (pname: {
            name = pname;
            value = getAllDeps pname;
          }) workspaceCrates
        );

        # Full source for workspace-wide operations
        fullSrc = craneLib.cleanCargoSource ./.;

        # Create filtered source that only includes specific crates
        mkFilteredSrc =
          crates:
          let
            crateSet = builtins.listToAttrs (
              map (c: {
                name = c;
                value = true;
              }) crates
            );

            # Find which crate (if any) a path belongs to
            getCrateForPath =
              relPath:
              pkgs.lib.findFirst (
                name:
                let
                  p = cratePaths.${name};
                in
                relPath == "/${p}" || pkgs.lib.hasPrefix "/${p}/" relPath
              ) null workspaceCrates;

            # Check if path is a parent directory of any workspace crate
            isParentOfCrate =
              relPath: pkgs.lib.any (path: pkgs.lib.hasPrefix "${relPath}/" "/${path}") workspaceMemberPaths;

            # Filter source files
            filteredSrc = pkgs.lib.cleanSourceWith {
              src = ./.;
              filter =
                path: type:
                let
                  relPath = pkgs.lib.removePrefix (toString ./.) (toString path);
                  # Which crate does this path belong to?
                  matchingCrate = getCrateForPath relPath;
                  # Is this an irrelevant crate? (in a crate dir but not in our set)
                  isIrrelevantCrate = matchingCrate != null && !(crateSet ? ${matchingCrate});
                in
                # Exclude irrelevant crate directories entirely
                if isIrrelevantCrate then
                  false
                # Keep root-level files (except Cargo.toml which we'll replace)
                else if type == "regular" && builtins.match "/[^/]+" relPath != null then
                  true
                # Keep directories that are parents of crate paths
                else if type == "directory" && isParentOfCrate relPath then
                  true
                # For everything else, use crane's filter (which handles .rs, Cargo.toml, etc.)
                else
                  craneLib.filterCargoSources path type;
            };

            # Generate a Cargo.toml with only the relevant members listed
            filteredCargoTomlContent = (pkgs.formats.toml { }).generate "Cargo.toml" (
              workspaceCargoToml
              // {
                workspace = workspaceCargoToml.workspace // {
                  members = map (c: cratePaths.${c}) crates;
                };
              }
            );
          in

          # Combine filtered source with the modified Cargo.toml
          pkgs.runCommand "filtered-workspace-${builtins.concatStringsSep "-" crates}" { } ''
            cp -r ${filteredSrc} $out
            chmod -R u+w $out
            cp ${filteredCargoTomlContent} $out/Cargo.toml
          '';

        # Common build inputs (uses full source for deps)
        commonArgs = {
          src = fullSrc;
          strictDeps = true;
        };

        # Build dependencies separately for caching (uses full workspace)
        # This is used for workspace-wide operations like clippy and tests
        cargoArtifacts = craneLib.buildDepsOnly commonArgs;

        # Build the workspace (uses full source)
        workspace = craneLib.buildPackage (
          commonArgs
          // {
            inherit cargoArtifacts;
          }
        );

        # Build per-package dependencies (only compiles deps that package needs)
        mkPackageDeps =
          pname:
          let
            deps = packageDeps.${pname} or [ ];
            relevantCrates = [ pname ] ++ deps;
            filteredSrc = mkFilteredSrc relevantCrates;
          in
          craneLib.buildDepsOnly {
            src = filteredSrc;
            pname = "${pname}-deps";
            # Only build deps for this specific package
            cargoExtraArgs = "-p ${pname}";
            strictDeps = true;
          };

        # Build individual packages with their own filtered deps
        mkPackage =
          pname:
          let
            deps = packageDeps.${pname} or [ ];
            relevantCrates = [ pname ] ++ deps;
            filteredSrc = mkFilteredSrc relevantCrates;
            packageCargoArtifacts = mkPackageDeps pname;
          in
          craneLib.buildPackage {
            src = filteredSrc;
            cargoArtifacts = packageCargoArtifacts;
            inherit pname;
            cargoExtraArgs = "-p ${pname}";
            strictDeps = true;
          };

        # Generate all workspace packages
        workspacePackages = builtins.listToAttrs (
          map (pname: {
            name = pname;
            value = mkPackage pname;
          }) workspaceCrates
        );

      in
      {
        checks = {
          inherit workspace;
        }
        // workspacePackages
        // {

          # Run clippy
          clippy = craneLib.cargoClippy (
            commonArgs
            // {
              inherit cargoArtifacts;
              cargoClippyExtraArgs = "--all-targets -- --deny warnings";
            }
          );

          # Run tests
          tests = craneLib.cargoTest (
            commonArgs
            // {
              inherit cargoArtifacts;
            }
          );

          # Check formatting
          fmt = craneLib.cargoFmt {
            src = fullSrc;
          };
        };

        packages = {
          default = workspace;
        }
        // workspacePackages;

        devShells.default = craneLib.devShell {
          checks = self.checks.${system};

          packages = with pkgs; [
            rust-analyzer
          ];
        };
      }
    );
}
