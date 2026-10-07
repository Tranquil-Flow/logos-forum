{
  description = "LP-0026 Forum — text-first Logos Basecamp module (privacy-required posting, verifiable archives)";

  # Official public Logos build cache (read-only; same key the delivery/storage
  # module flakes declare). Lets pinned prebuilt artifacts substitute instead
  # of compiling Rust/Nim closures from source.
  nixConfig = {
    extra-substituters = [ "https://cache.nix.logos.co/public" ];
    extra-trusted-public-keys = [ "public:l4HrXgL4nw246+LBh2SOJyhz64BoGegOYLheT/iIAPU=" ];
  };

  inputs = {
    # Pinned builder closure: tag 0.3.2 == rev 4b7998272c5ec014bcac4bf1c7dbe7602c63a3c1
    logos-module-builder.url = "github:logos-co/logos-module-builder/0.3.2";

    # Reuse the builder's exact nixpkgs for the Qt-free core test derivation.
    nixpkgs.follows = "logos-module-builder/nixpkgs";

    # M1 typed transport/storage dependencies. Names match metadata.json
    # "dependencies" (load-bearing: the builder resolves each input by name and
    # generates typed modules().<name> wrappers from the dep's published LIDL,
    # derived at build time from the dep's impl header). Pins match the
    # qualified release tuple (docs/PINS.json).
    delivery_module.url = "github:logos-co/logos-delivery-module/v0.3.2";
    storage_module.url = "github:logos-co/logos-storage-module/v3.0.0";
  };

  outputs = inputs@{ logos-module-builder, nixpkgs, ... }:
    let
      base = logos-module-builder.lib.mkLogosQmlModule {
        src = ./.;
        configFile = ./metadata.json;
        flakeInputs = inputs;
      };
      # Qt-free domain-core tests (tests/core + src/core), no GUI/network.
      mkCoreTests = system: pkgs:
        pkgs.runCommand "forum-core-tests" {
          nativeBuildInputs = [ pkgs.clang ];
          buildInputs = [ pkgs.sqlite.dev pkgs.libsodium ];
        } ''
          mkdir -p $out
          clang++ -std=c++17 -O1 -Wall \
            ${./src/core/forum_core.cpp} ${./src/archive/archive_core.cpp} \
            ${./tests/core/test_main.cpp} \
            -I${./src/core} -I${./src/archive} \
            -I${pkgs.sqlite.dev}/include -I${pkgs.libsodium}/include \
            -L${pkgs.sqlite.out}/lib -L${pkgs.libsodium}/lib \
            -lsqlite3 -lsodium \
            -o $out/core_tests
          $out/core_tests | tee $out/test-output.txt
        '';
    in
    base // {
      packages = builtins.mapAttrs (system: pkgsSet:
        (base.packages.${system} or { }) // {
          core-tests = mkCoreTests system (import nixpkgs {
            inherit system;
            config = { };
          });
          # Python for the tools/ harnesses (only third-party dep: cryptography).
          harness-python = (import nixpkgs { inherit system; config = { }; }).python3.withPackages
            (ps: [ ps.cryptography ]);
        } // nixpkgs.lib.optionalAttrs ((base.packages.${system} or { }) ? integration-test) {
          # Give the backend a writable store inside the build sandbox (the
          # default AppDataLocation resolves under unwritable /var/empty), so
          # the store-backed flows (aliases, topics, per-post states) run in CI.
          integration-test = base.packages.${system}.integration-test.overrideAttrs (old: {
            buildCommand = ''
              export FORUM_DB_PATH="$TMPDIR/forum-ci.db"
            '' + old.buildCommand;
          });
        }
      ) (base.packages or { });
    };
}
