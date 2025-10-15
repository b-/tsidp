{
  description = "tsidp - A simple OIDC / OAuth Identity Provider (IdP) server for your tailnet.";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
    systems.url = "github:nix-systems/default";
  };

  outputs =
    {
      self,
      nixpkgs,
      systems,
    }:
    let
      goVersion = "1.24.7";
      goHash = "sha256-Ko9Q2w+IgDYHxQ1+qINNy3vUg8a0KKkeNg/fhiS0ZGQ=";
      eachSystem =
        f:
        nixpkgs.lib.genAttrs (import systems) (
          system:
          f (
            import nixpkgs {
              inherit system;
              overlays = [
                (final: prev: {
                  go_1_24 = prev.go_1_24.overrideAttrs {
                    version = goVersion;
                    src = prev.fetchurl {
                      url = "https://go.dev/dl/go${goVersion}.src.tar.gz";
                      hash = goHash;
                    };
                  };
                })
              ];
            }
          )
        );
    in
    {
      formatter = eachSystem (pkgs: pkgs.nixfmt-tree);

      packages = eachSystem (pkgs: {
        tsidp = pkgs.buildGo124Module {
          pname = "tsidp";
          version = if (self ? shortRev) then self.shortRev else "dev";
          src = pkgs.nix-gitignore.gitignoreSource [ ] ./.;
          meta.mainProgram = "tsidp";
          ldflags =
            let
              tsVersion =
                with builtins;
                head (match ".*tailscale.com v([0-9]+\.[0-9]+\.[0-9]+-?[a-zA-Z]?).*" (readFile ./go.mod));
            in
            [
              "-w"
              "-s"
              "-X tailscale.com/version.longStamp=${tsVersion}"
              "-X tailscale.com/version.shortStamp=${tsVersion}"
            ];
          vendorHash = "sha256-obtcJTg7V4ij3fGVmZMD7QQwKJX6K5PPslpM1XKCk9Q="; # SHA based on vendoring go.mod
        };

        default = self.packages.${pkgs.system}.tsidp;
      });

      overlays.default = final: prev: {
        tsidp = self.packages.${final.system}.tsidp;
      };

      devShells = eachSystem (pkgs: {
        default = pkgs.mkShell {
          packages = [
            pkgs.go_1_24
            pkgs.gopls
          ];
        };
      });

      nixosModules.default =
        {
          lib,
          pkgs,
          config,
          ...
        }:
        let
          inherit (lib)
            getExe
            mkEnableOption
            mkIf
            mkOption
            mkPackageOption
            optional
            ;
          inherit (lib.types)
            str
            port
            bool
            enum
            nullOr
            ;

          cfg = config.services.tsidp;

          stateDir = "/var/lib/tsidp";
        in
        {
          options.services.tsidp = {
            enable = mkEnableOption "tsidp server";

            package = mkOption {
              type = lib.types.package;
              default = self.packages.${pkgs.system}.tsidp;
              description = "Package to use for the tsidp service.";
            };

            environmentFile = mkOption {
              type = nullOr lib.types.path;
              description = ''
                Path to an environment file loaded for the tsidp service.

                This can be used to securely store tokens and secrets outside of the world-readable Nix store.

                Example contents of the file:
                ```
                TS_AUTH_KEY=YOUR_TAILSCALE_AUTHKEY
                ```
              '';
              default = null;
              example = "/run/secrets/tsidp";
            };

            settings = {
              hostName = mkOption {
                type = str;
                default = "idp";
                description = ''
                  The hostname to use for the tsnet node.
                '';
              };

              port = mkOption {
                type = port;
                default = 443;
                description = ''
                  Port to listen on (default: 443).
                '';
              };

              localPort = mkOption {
                type = nullOr port;
                default = null;
                description = "Listen on localhost:<port>.";
              };

              useLocalTailscaled = mkOption {
                type = bool;
                description = ''
                  Use local tailscaled instead of tsnet.
                '';
                default = false;
              };

              enableFunnel = mkOption {
                type = bool;
                default = false;
                description = ''
                  Use Tailscale Funnel to make tsidp available on the public internet so it works with SaaS products.
                '';
              };

              enableSts = mkOption {
                type = bool;
                default = true;
                description = ''
                  Enable OAuth token exchange using RFC 8693.
                '';
              };

              logLevel = mkOption {
                type = enum [
                  "debug"
                  "info"
                  "warn"
                  "error"
                ];
                description = ''
                  Set logging level: debug, info, warn, error.
                '';
                default = "info";
              };

              debugAllRequests = mkOption {
                type = bool;
                description = ''
                  For development. Prints all requests and responses.
                '';
                default = false;
              };

              debugTsnet = mkOption {
                type = bool;
                description = ''
                  For development. Enables debug level logging with tsnet connection.
                '';
                default = false;
              };
            };
          };

          config = mkIf cfg.enable {
            assertions = [
              {
                assertion = cfg.settings.useLocalTailscaled -> config.services.tailscale.enable == true;
                message = "Tailscale service must be enabled if services.tsidp.settings.useLocalTailscaled is used.";
              }
            ];

            systemd.services.tsidp =
              let
                deps = [
                  "network.target"
                ]
                ++ optional (cfg.settings.useLocalTailscaled) "tailscaled.service";
              in
              {
                description = "tsidp";
                after = deps;
                wants = deps;
                wantedBy = [
                  "multi-user.target"
                  "network-online.target"
                ];
                restartTriggers = [
                  cfg.package
                  cfg.environmentFile
                ];

                environment = {
                  HOME = stateDir;
                  TAILSCALE_USE_WIP_CODE = "1"; # Needed while tsidp is in development (< v1.0.0).
                };

                serviceConfig = {
                  Type = "simple";
                  ExecStart =
                    let
                      args = lib.cli.toGNUCommandLineShell { mkOptionName = k: "-${k}"; } {
                        hostname = cfg.settings.hostName;
                        port = cfg.settings.port;
                        local-port = cfg.settings.localPort;
                        use-local-tailscaled = cfg.settings.useLocalTailscaled;
                        funnel = cfg.settings.enableFunnel;
                        enable-sts = cfg.settings.enableSts;
                        log = cfg.settings.logLevel;
                        debug-all-requests = cfg.settings.debugAllRequests;
                        debug-tsnet = cfg.settings.debugTsnet;
                        dir = stateDir;
                      };
                    in
                    "${getExe cfg.package} ${args}";
                  Restart = "always";
                  RestartSec = "15";

                  DynamicUser = true;
                  StateDirectory = baseNameOf stateDir;
                  WorkingDirectory = stateDir;
                  ReadWritePaths = mkIf (cfg.settings.useLocalTailscaled) [
                    "/var/run/tailscale" # needed due to `ProtectSystem = "strict";`
                    "/var/lib/tailscale"
                  ];
                  BindPaths = mkIf (cfg.settings.useLocalTailscaled) [
                    "/var/run/tailscale:/var/run/tailscale"
                  ];

                  EnvironmentFile = mkIf (cfg.environmentFile != null) cfg.environmentFile;

                  # Hardening
                  AmbientCapabilities = "";
                  CapabilityBoundingSet = "";
                  DeviceAllow = "";
                  DevicePolicy = "closed";
                  LockPersonality = true;
                  MemoryDenyWriteExecute = true;
                  NoNewPrivileges = true;
                  PrivateNetwork = false; # provides the service through network
                  PrivateTmp = true;
                  PrivateUsers = true;
                  PrivateDevices = true;
                  ProtectHome = true;
                  ProtectClock = true;
                  ProtectControlGroups = true;
                  ProtectKernelModules = true;
                  ProtectKernelLogs = true;
                  ProtectKernelTunables = true;
                  ProtectSystem = "strict";
                  ProtectHostname = true;
                  ProtectProc = "invisible";
                  ProcSubset = "all"; # tsidp needs access to /proc/net/route
                  RestrictAddressFamilies = [
                    "AF_INET"
                    "AF_INET6"
                    "AF_UNIX"
                    "AF_NETLINK"
                  ];
                  RestrictRealtime = true;
                  RestrictNamespaces = true;
                  RestrictSUIDSGID = true;
                  SystemCallArchitectures = "native";
                  SystemCallFilter = [ "@system-service" ];
                };
              };
          };
        };
    };
}
