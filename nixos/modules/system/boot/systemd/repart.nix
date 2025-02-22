{ config, pkgs, lib, ... }:

let
  cfg = config.systemd.repart;
  initrdCfg = config.boot.initrd.systemd.repart;

  writeDefinition = name: partitionConfig: pkgs.writeText
    "${name}.conf"
    (lib.generators.toINI { } { Partition = partitionConfig; });

  listOfDefinitions = lib.mapAttrsToList
    writeDefinition
    (lib.filterAttrs (k: _: !(lib.hasPrefix "_" k)) cfg.partitions);

  # Create a directory in the store that contains a copy of all definition
  # files. This is then passed to systemd-repart in the initrd so it can access
  # the definition files after the sysroot has been mounted but before
  # activation. This needs a hard copy of the files and not just symlinks
  # because otherwise the files do not show up in the sysroot.
  definitionsDirectory = pkgs.runCommand "systemd-repart-definitions" { } ''
    mkdir -p $out
    ${(lib.concatStringsSep "\n"
      (map (pkg: "cp ${pkg} $out/${pkg.name}") listOfDefinitions)
    )}
  '';
in
{
  options = {
    boot.initrd.systemd.repart.enable = lib.mkEnableOption (lib.mdDoc "systemd-repart") // {
      description = lib.mdDoc ''
        Grow and add partitions to a partition table at boot time in the initrd.
        systemd-repart only works with GPT partition tables.

        To run systemd-repart after the initrd, see
        `options.systemd.repart.enable`.
      '';
    };

    systemd.repart = {
      enable = lib.mkEnableOption (lib.mdDoc "systemd-repart") // {
        description = lib.mdDoc ''
          Grow and add partitions to a partition table.
          systemd-repart only works with GPT partition tables.

          To run systemd-repart while in the initrd, see
          `options.boot.initrd.systemd.repart.enable`.
        '';
      };

      partitions = lib.mkOption {
        type = with lib.types; attrsOf (attrsOf (oneOf [ str int bool ]));
        default = { };
        example = {
          "10-root" = {
            Type = "root";
          };
          "20-home" = {
            Type = "home";
            SizeMinBytes = "512M";
            SizeMaxBytes = "2G";
          };
        };
        description = lib.mdDoc ''
          Specify partitions as a set of the names of the definition files as the
          key and the partition configuration as its value. The partition
          configuration can use all upstream options. See <link
          xlink:href="https://www.freedesktop.org/software/systemd/man/repart.d.html"/>
          for all available options.
        '';
      };
    };
  };

  config = lib.mkIf (cfg.enable || initrdCfg.enable) {
    boot.initrd.systemd = lib.mkIf initrdCfg.enable {
      additionalUpstreamUnits = [
        "systemd-repart.service"
      ];

      storePaths = [
        "${config.boot.initrd.systemd.package}/bin/systemd-repart"
      ];

      contents."/etc/repart.d".source = definitionsDirectory;

      # Override defaults in upstream unit.
      services.systemd-repart = {
        # systemd-repart tries to create directories in /var/tmp by default to
        # store large temporary files that benefit from persistence on disk. In
        # the initrd, however, /var/tmp does not provide more persistence than
        # /tmp, so we re-use it here.
        environment."TMPDIR" = "/tmp";
        serviceConfig = {
          ExecStart = [
            " " # required to unset the previous value.
            # When running in the initrd, systemd-repart by default searches
            # for definition files in /sysroot or /sysusr. We tell it to look
            # in the initrd itself.
            ''${config.boot.initrd.systemd.package}/bin/systemd-repart \
                  --definitions=/etc/repart.d \
                  --dry-run=no
            ''
          ];
        };
        # systemd-repart needs to run after /sysroot (or /sysuser, but we don't
        # have it) has been mounted because otherwise it cannot determine the
        # device (i.e disk) to operate on. If you want to run systemd-repart
        # without /sysroot, you have to explicitly tell it which device to
        # operate on.
        after = [ "sysroot.mount" ];
      };
    };

    environment.etc = lib.mkIf cfg.enable {
      "repart.d".source = definitionsDirectory;
    };

    systemd = lib.mkIf cfg.enable {
      additionalUpstreamSystemUnits = [
        "systemd-repart.service"
      ];
    };
  };

  meta.maintainers = with lib.maintainers; [ nikstur ];
}
