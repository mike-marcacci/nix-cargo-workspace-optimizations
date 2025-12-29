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

        # Common source filtering
        src = craneLib.cleanCargoSource ./.;

        # Common build inputs
        commonArgs = {
          inherit src;
          strictDeps = true;
        };

        # Build dependencies separately for caching
        cargoArtifacts = craneLib.buildDepsOnly commonArgs;

        # Build the workspace
        workspace = craneLib.buildPackage (
          commonArgs
          // {
            inherit cargoArtifacts;
          }
        );

        # Build individual packages
        mkPackage =
          pname:
          craneLib.buildPackage (
            commonArgs
            // {
              inherit cargoArtifacts pname;
              cargoExtraArgs = "-p ${pname}";
            }
          );

        pkg-a = mkPackage "pkg-a";
        pkg-b = mkPackage "pkg-b";
        pkg-c = mkPackage "pkg-c";
        pkg-d = mkPackage "pkg-d";

      in
      {
        checks = {
          inherit
            workspace
            pkg-a
            pkg-b
            pkg-c
            pkg-d
            ;

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
            inherit src;
          };
        };

        packages = {
          default = workspace;
          inherit
            pkg-a
            pkg-b
            pkg-c
            pkg-d
            ;
        };

        devShells.default = craneLib.devShell {
          checks = self.checks.${system};

          packages = with pkgs; [
            rust-analyzer
          ];
        };
      }
    );
}
