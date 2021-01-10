{ config, pkgs, ... }:

let
  nixServe = rec {
    keyDirectory = "/etc/nix-serve";

    privateKey = "${keyDirectory}/nix-serve.sec";

    publicKey = "${keyDirectory}/nix-serve.pub";
  };

in

{ imports =
    let
      nixos-mailserver =
        builtins.fetchTarball {
          url = "https://gitlab.com/simple-nixos-mailserver/nixos-mailserver/-/archive/v2.3.0/nixos-mailserver-v2.2.0.tar.gz";

          sha256 = "0lpz08qviccvpfws2nm83n7m2r8add2wvfg9bljx9yxx8107r919";
        };

    in
      [ nixos-mailserver ];

  environment = {
    etc =
      let
        toProject = suffix: {
          name = "hydra/dhall-${suffix}.json";

          value = { text = builtins.toJSON (import ./project.nix suffix); };
        };

        suffixes = [
          "bash"
          "haskell"
          "json"
          "kubernetes"
          "lang"
          "nix"
          "text"
          "to-cabal"
        ];

      in
        builtins.listToAttrs (builtins.map toProject suffixes) // {
          "hydra/jobsets.nix".text = builtins.readFile ./jobsets.nix;

          "hydra/machines".text = ''
            localhost x86_64-linux,builtin - 4 1 local,big-parallel
          '';
        };
  };

  mailserver = {
    enable = true;

    certificateScheme = 3;

    domains = [ "discourse.dhall-lang.org" "dhall-lang.org" ];

    enableImap = true;
    enableImapSsl = true;
    enablePop3 = true;
    enablePop3Ssl = true;

    fqdn = "mail.dhall-lang.org";

    loginAccounts = {
      "discourse@dhall-lang.org" = {
        hashedPassword = "$6$.vCIyiyMp4/HzO$FyW1OMFpL7tmPQvfDs2wDfhn5qTZW4NePBfDsrFQxPepIISrFYyjISeZS2kAHO6F/AolD7sus2mJUXsQUgCfv0";

        aliases = [ "postmaster@dhall-lang.org" ];
      };
    };

    policydSPFExtraConfig = ''
      skip_addresses = 172.17.0.2/32,127.0.0.0/8,::ffff:127.0.0.0/104,::1
    '';
  };

  networking.firewall.allowedTCPPorts = [ 22 80 443 ];

  nix = {
    autoOptimiseStore = true;

    gc = {
      automatic = true;

      options = "--delete-older-than 30d";
    };

    useSandbox = false;

    trustedUsers = [ "gabriel" ];
  };

  nixpkgs.overlays =
    let
      modifyHydra = pkgsNew: pkgsOld: {
        hydra-unstable = pkgsOld.hydra-unstable.overrideAttrs (old: {
            patches = (old.patches or []) ++ [
              ./hydra.patch
              ./no-restrict-eval.patch
              (pkgsNew.fetchpatch {
                  url = "https://github.com/NixOS/hydra/commit/df3262e96cb55bdfaac7726896728bfef675698b.patch";

                  sha256 = "1344cqlmx0ncgsh3dqn5igbxx6rgmlm14rgb5vi6rxkvwnfqy3zj";
                }
              )
            ];
          }
        );
      };

      addDhallPackages = pkgsNew: pkgsOld: {
        dhallPackages = pkgsOld.dhallPackages.override (old: {
            overrides =
              let
                directoryOverrides = dhallPackagesNew: dhallPackagesOld:
                  let
                    files = builtins.readDir ./packages;

                    toPackage = file: _ :
                      { name =
                          builtins.replaceStrings [ ".nix" ] [ "" ] file;

                        value =
                          dhallPackagesNew.callPackage
                            (./packages + "/${file}")
                            { };
                      };

                  in
                    pkgs.lib.mapAttrs' toPackage files;

              in
                pkgsNew.lib.composeExtensions
                  (old.overrides or (_: _: {}))
                  directoryOverrides;
          }
        );
      };

    in
      [ modifyHydra addDhallPackages ];

  programs.ssh.knownHosts."github.com".publicKey =
      "ssh-rsa AAAAB3NzaC1yc2EAAAABIwAAAQEAq2A7hRGmdnm9tUDbO9IDSwBK6TbQa+PXYPCPy6rbTrTtw7PHkccKrpp0yVhp5HdEIcKr6pLlVDBfOLX9QUsyCOV0wzfjIJNlGEYsdlLJizHhbn2mUjvSAHQqZETYP81eFzLQNnPHt4EVVUh7VfDESU84KezmD5QlWpXLmvU31/yMf+Se8xhHTvKSCZIFImWwoG6mbUoWf9nzpIoaSjB+weqqUUmpaaasXVal72J+UX2B+2RPW3RcT0eOzQgqlJL3RKrTJvdsjE3JEAvGq3lGHSZXy28G3skua2SmVi/w4yCE6gbODqnTWlg7+wC604ydGXA8VJiS5ap43JXiUFFAaQ==";

  security = {
    acme = {
      acceptTerms = true;

      email = "Gabriel439@gmail.com";
    };

    sudo.wheelNeedsPassword = false;
  };

  services = {
    fail2ban.enable = true;

    hydra = {
      buildMachinesFiles = [ "/etc/hydra/machines" ];

      enable = true;

      extraConfig = ''
        <githubstatus>
          jobs = .*:.*:dhall.*
          inputs = src
          authorization = dhall-lang
          context = hydra
        </githubstatus>
        binary_cache_secret_key_file = ${nixServe.privateKey}
      '';

      hydraURL = "https://hydra.dhall-lang.org";

      listenHost = "127.0.0.1";

      logo = ../img/dhall-logo.png;

      notificationSender = "noreply@dhall-lang.org";

      package = pkgs.hydra-unstable;
    };

    journald.extraConfig = ''
      SystemMaxUse=100M
    '';

    logrotate = {
      enable = true;

      extraConfig = ''
        /var/spool/nginx/logs/*.log {
          create 0644 nginx nginx
          daily
          rotate 7
          missingok
          notifempty
          compress
          sharedscripts
          postrotate
            kill -USR1 "$(${pkgs.coreutils}/bin/cat /run/nginx/nginx.pid 2>/dev/null)" > /dev/null || true
          endscript
        }
      '';
    };

    nginx = {
      enable = true;

      package = pkgs.nginxStable.override {
        modules = with pkgs.nginxModules; [ develkit echo set-misc ];
      };

      recommendedGzipSettings = true;

      recommendedOptimisation = true;

      recommendedTlsSettings = true;

      virtualHosts =
        let
          latestRelease = "v20.0.0";

          prelude = {
            forceSSL = true;

            enableACME = true;

            locations."/" = {
              extraConfig = ''
                if ($request_method = 'OPTIONS') {
                  add_header 'Access-Control-Allow-Origin' "*";
                  add_header 'Access-Control-Allow-Methods' 'GET, OPTIONS';
                  add_header 'Access-Control-Allow-Headers' 'DNT,User-Agent,X-Requested-With,If-Modified-Since,Cache-Control,Content-Type,Range';
                  add_header 'Access-Control-Max-Age' 600;
                  add_header 'Content-Type' 'text/plain; charset=utf-8';
                  add_header 'Content-Length' 0;
                  return 204;
                }
                if ($request_method = 'GET') {
                  add_header 'Access-Control-Allow-Methods' 'GET, OPTIONS';
                  add_header 'Access-Control-Allow-Headers' 'DNT,User-Agent,X-Requested-With,If-Modified-Since,Cache-Control,Content-Type,Range';
                  add_header 'Access-Control-Expose-Headers' 'Content-Length,Content-Range';
                }

                rewrite ^/?$ https://github.com/dhall-lang/dhall-lang/tree/${latestRelease}/Prelude redirect;
                rewrite ^/(v[^/]+)$ https://github.com/dhall-lang/dhall-lang/tree/$1/Prelude redirect;
                rewrite ^/(v[^/]+)/(.*)$ /dhall-lang/dhall-lang/$1/Prelude/$2 break;
                rewrite ^/(.*)$ /dhall-lang/dhall-lang/${latestRelease}/Prelude/$1 break;
              '';
              proxyPass = "https://raw.githubusercontent.com";
            };
          };

        in
          { "dhall-lang.org" =
              let
                inherit (pkgs) website;

              in
              { forceSSL = true;

                default = true;

                enableACME = true;

                locations."/" = {
                  index = "index.html";

                  root = "${website}";
                };
              };

          "cache.dhall-lang.org" = {
            forceSSL = true;

            enableACME = true;

            locations."/".proxyPass = "http://127.0.0.1:5000";
          };

          "discourse.dhall-lang.org" = {
            forceSSL = true;

            extraConfig = ''
              proxy_set_header Host $host;
              proxy_set_header X-Real-IP $remote_addr;
              proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
              proxy_set_header X-Forwarded-Proto $scheme;
              proxy_set_header X-Forwarded-Host $host;
              proxy_set_header X-Forwarded-Server $host;
              proxy_set_header Accept-Encoding "";
            '';

            enableACME = true;

            locations."/".proxyPass = "http://unix:/var/discourse/shared/standalone/nginx.http.sock";
          };

          "docs.dhall-lang.org" =
            let
              dhall-lang-derivations = import ../release.nix { };

              inherit (dhall-lang-derivations) docs;

            in
              { forceSSL = true;

                enableACME = true;

                locations."/" = {
                  index = "index.html";

                  root = "${docs}";
                };
              };

          "hydra.dhall-lang.org" = {
            forceSSL = true;

            extraConfig = ''
              proxy_set_header Host $host;
              proxy_set_header X-Real-IP $remote_addr;
              proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
              proxy_set_header X-Forwarded-Proto $scheme;
              proxy_set_header X-Forwarded-Host $host;
              proxy_set_header X-Forwarded-Server $host;
              proxy_set_header Accept-Encoding "";
            '';

            enableACME = true;

            locations."/".proxyPass = "http://127.0.0.1:3000";
          };

          "prelude.dhall-lang.org" = prelude;

          "store.dhall-lang.org" =
            let
              packages = with pkgs.dhallPackages; [
                dhall-ansible_0_1_0

                dhall-concourse_0_4_1
                dhall-concourse_0_5_0
                dhall-concourse_0_5_1
                dhall-concourse_0_5_2
                dhall-concourse_0_6_0
                dhall-concourse_0_6_1
                dhall-concourse_0_7_0
                dhall-concourse_0_7_1
                dhall-concourse_0_8_0
                dhall-concourse_0_9_0
                dhall-concourse_0_9_1

                dhall-dot_1_0_0

                dhall-kops_0_4_0
                dhall-kops_0_4_1
                dhall-kops_0_5_0
                dhall-kops_0_5_1

                dhall-kubernetes_3_0_0
                dhall-kubernetes_4_0_0
                dhall-kubernetes_5_0_0

                dhall-semver_1_0_0

                Prelude_14_0_0
                Prelude_15_0_0
                Prelude_16_0_0
                Prelude_17_0_0
                Prelude_18_0_0
                Prelude_19_0_0
                Prelude_20_0_0
              ];

              store = pkgs.runCommand "store" { inherit packages; } ''
                mkdir "$out"

                for package in $packages; do
                  ${pkgs.xorg.lndir}/bin/lndir -silent "$package/.cache/dhall" "$out"
                done
              '';

            in
              { forceSSL = true;

                enableACME = true;

                locations."/" = {
                  root = "${store}";

                  extraConfig = ''
                    default_type application/dhall+cbor;
                  '';
                };
              };

          # Same as `prelude.dhall-lang.org` except requires a header named
          # `Test` to be present to authorize requests.  This is used to test
          # support for header forwarding for the test suite.
          "test.dhall-lang.org" =
            pkgs.lib.mkMerge
              [ prelude
                { locations."/".extraConfig = ''
                    if ($http_test = "") {
                      return 403;
                    }
                  '';
                  locations."/random-string".extraConfig = ''
                    set_secure_random_alphanum $res 32;
                    echo $res;
                  '';
                }
              ];
        };
    };

    nix-serve = {
      bindAddress = "127.0.0.1";

      enable = true;

      secretKeyFile = nixServe.privateKey;
    };

    openssh.enable = true;
  };

  systemd.services = {
    discourse =
      let
        discourseDirectory = "/var/discourse_docker";

        varDirectory = dirOf discourseDirectory;

        discourseSmtpPassword =
          let
            path = ./discourseSmtpPassword;

          in
            if builtins.pathExists path then builtins.readFile path else "";

        discourseConfiguration =
          pkgs.writeText "discourse-app.yaml" ''
            templates:
              - "templates/postgres.template.yml"
              - "templates/redis.template.yml"
              - "templates/web.template.yml"
              - "templates/web.ratelimited.template.yml"
              - "templates/web.socketed.template.yml"

            expose: []

            params:
              db_default_text_search_config: "pg_catalog.english"

              db_shared_buffers: "256MB"

              db_work_mem: "40MB"

              version: 41f09ee29c44424901054a7dbe0bf8c0a9b86742

            env:
              LANG: en_US.UTF-8

              UNICORN_WORKERS: 1

              DISCOURSE_HOSTNAME: 'discourse.dhall-lang.org'

              DISCOURSE_DEVELOPER_EMAILS: 'Gabriel439@gmail.com'

              DISCOURSE_SMTP_ADDRESS: mail.dhall-lang.org

              DISCOURSE_SMTP_USER_NAME: discourse@dhall-lang.org

              DISCOURSE_SMTP_PASSWORD: '${discourseSmtpPassword}'

              # TODO: Use CDN?
              #
              #DISCOURSE_CDN_URL: https://discourse-cdn.example.com

            volumes:
              - volume:
                  host: /var/discourse/shared/standalone
                  guest: /shared
              - volume:
                  host: /var/discourse/shared/standalone/log/var-log
                  guest: /var/log

            hooks:
              after_code:
                - exec:
                    cd: $home/plugins
                    cmd:
                      - git clone https://github.com/discourse/docker_manager.git

            run: []
          '';

      in
        { after = [ "network.target" "docker.service" ];

          path = [ pkgs.git pkgs.nettools pkgs.which pkgs.gawk pkgs.docker ];

          script = ''
            if [[ ! -e ${discourseDirectory} ]]; then
              ${pkgs.coreutils}/bin/mkdir --parents ${varDirectory}

              cd ${varDirectory}

              ${pkgs.git}/bin/git clone https://github.com/discourse/discourse_docker.git
            fi

            cd ${discourseDirectory}

            ${pkgs.git}/bin/git fetch https://github.com/discourse/discourse_docker.git 77edaf675a47729bb693d09b94713a2a98b5d686

            ${pkgs.git}/bin/git checkout FETCH_HEAD

            ${pkgs.coreutils}/bin/cp ${discourseConfiguration} ${discourseDirectory}/containers/app.yml

            ${pkgs.bash}/bin/bash ${discourseDirectory}/launcher rebuild app
          '';

          serviceConfig.RemainAfterExit = true;

          wantedBy = [ "multi-user.target" ];

          wants = [ "docker.service" ];
        };

    nix-serve-keys = {
      script = ''
        if [ ! -e ${nixServe.keyDirectory} ]; then
          mkdir -p ${nixServe.keyDirectory}
        fi

        if ! [ -e ${nixServe.privateKey} ] || ! [ -e ${nixServe.publicKey} ]; then
          ${pkgs.nix}/bin/nix-store --generate-binary-cache-key cache.dhall-lang.org ${nixServe.privateKey} ${nixServe.publicKey}
        fi

        chown -R nix-serve:hydra ${nixServe.keyDirectory}

        chmod 640 ${nixServe.privateKey}
      '';

      serviceConfig.Type = "oneshot";

      wantedBy = [ "multi-user.target" ];
    };

    self-deploy =
      let
        workingDirectory = "/var/lib/self-deploy";

        owner = "dhall-lang";

        repository = "dhall-lang";

        repositoryDirectory = "${workingDirectory}/${repository}";

        build = "${repositoryDirectory}/result";

      in
        { wantedBy = [ "multi-user.target" ];

          after = [ "network-online.target" ];

          path = [ pkgs.gnutar pkgs.gzip ];

          serviceConfig.X-RestartIfChanged = false;

          script = ''
            if [ ! -e ${workingDirectory} ]; then
              ${pkgs.coreutils}/bin/mkdir --parents ${workingDirectory}
            fi

            if [ ! -e ${repositoryDirectory} ]; then
              cd ${workingDirectory}
              ${pkgs.git}/bin/git clone git@github.com:${owner}/${repository}.git
            fi

            cd ${repositoryDirectory}

            ${pkgs.git}/bin/git fetch https://github.com/dhall-lang/dhall-lang.git master

            ${pkgs.git}/bin/git checkout FETCH_HEAD

            ${pkgs.nix}/bin/nix-build --attr machine ${repositoryDirectory}/release.nix

            ${pkgs.nix}/bin/nix-env --profile /nix/var/nix/profiles/system --set ${build}

            ${pkgs.git}/bin/git gc --prune=all

            ${build}/bin/switch-to-configuration switch
          '';

          startAt = "hourly";
        };
  };

  users.users = {
    gabriel = {
      isNormalUser = true;

      extraGroups = [ "wheel" ];

      openssh.authorizedKeys.keys = [
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGquu14+nGeuczn/u9wr2TD8L123DMOGLutPpXMDgMz5 gabriel@chickle"
      ];
    };

    philandstuff = {
      isNormalUser = true;

      extraGroups = [ "wheel" ];

      openssh.authorizedKeys.keys = [
        "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCFb1mAXG9cehfjq3FkEgRKMZW48d+IDE9YLbXruy283sf8UZYicKIFkht1nVd8MBd4/iWM23GXtLtyB4F5WXqeDpJFghfxDjoLkU146pSuAmqSOJo0HYOqiMYZJl6MeNtzzMjk6319WSQ80zI9eVNJqLAsTl5OfKHrqZBP32PC3CPQkCW8sQD8fbT/BG0tghUeC/X+LIho0enF58vN180IDsTjcJTjKGu/WzPU6RkyfNoE9LM2cjDKQ4nhucYZs03rklBKUbNB3FW5BM2/AKMzRJ5IkcMiqg6YOkkpB2rw0kbPW0/tAws1lvK8/aoCDw+ou8d4G4jYWqUEl7Okcryd PIV AUTH pubkey"
      ];
    };
  };

  virtualisation.docker = {
    enable = true;

    autoPrune = {
      enable = true;

      flags = [ "--all" ];
    };

    storageDriver = "overlay2";
  };
}
