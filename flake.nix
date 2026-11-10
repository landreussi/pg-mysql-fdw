{
  description = "Bookstore strangler-fig PoC: legacy MySQL + PostgreSQL joined through mysql_fdw";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = {
    self,
    nixpkgs,
  }: let
    systems = [
      "x86_64-linux"
      "aarch64-linux"
      "x86_64-darwin"
      "aarch64-darwin"
    ];
    forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
  in {
    packages = forAllSystems (
      pkgs: let
        # 8.4 is the current MySQL LTS (8.0 is EOL and gone from nixpkgs).
        mysql = pkgs.mysql84;
        mysql_fdw = pkgs.postgresql_18.pkgs.callPackage ./nix/mysql_fdw.nix {inherit mysql;};
        postgresql = pkgs.postgresql_18.withPackages (_: [mysql_fdw]);
        # Benchmark harness (bench/bench.py)
        python = pkgs.python3.withPackages (ps: [
          ps.psycopg
          ps.pymysql
        ]);
      in {
        default = self.packages.${pkgs.stdenv.hostPlatform.system}.bookstore;
        inherit mysql mysql_fdw postgresql;
        bookstore = pkgs.writeShellApplication {
          name = "bookstore";
          runtimeInputs = [
            mysql
            postgresql
            python
            pkgs.git
            pkgs.coreutils
            pkgs.util-linux # setsid
          ];
          text = builtins.readFile ./nix/bookstore.sh;
        };
      }
    );

    apps = forAllSystems (pkgs: {
      default = {
        type = "app";
        program = "${self.packages.${pkgs.stdenv.hostPlatform.system}.bookstore}/bin/bookstore";
      };
    });

    devShells = forAllSystems (pkgs: let
      packages = self.packages.${pkgs.stdenv.hostPlatform.system};
    in {
      default = pkgs.mkShell {
        packages = [
          # up: start both servers (seeding on first run), bench: run the benchmark
          packages.bookstore
          packages.postgresql
          packages.mysql
        ];
        shellHook = ''
          eval "$(${packages.bookstore}/bin/bookstore env)"
          ${packages.bookstore}/bin/bookstore help
        '';
      };
    });
  };
}
