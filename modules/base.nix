{ config, pkgs, lib, sshPubKey, ... }:

{
  imports = [ ./cloudflared.nix ];

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  networking.networkmanager.enable = true;

  services.openssh = {
    enable = true;
    settings = {
      # Key-only. Root login is allowed, but only with an authorized key —
      # no passwords anywhere.
      PermitRootLogin = "prohibit-password";
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      # Hardening: only the admin accounts may authenticate; cap the pre-auth
      # window and brute-force attempts.
      AllowUsers = [ "root" "calamansi" ];
      MaxAuthTries = 3;
      LoginGraceTime = 30;
      ClientAliveInterval = 300;
      ClientAliveCountMax = 2;
      X11Forwarding = false;
    };
  };

  users.users.calamansi = {
    isNormalUser = true;
    extraGroups = [ "wheel" "networkmanager" ];
    openssh.authorizedKeys.keys = [ sshPubKey ];
  };

  # Root SSH access for the admin workstation (rebuild-safe: must be declarative,
  # otherwise a fresh install is unreachable).
  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILj/syjQTnLwTGNHC4IKec2QXJpzXOExBQKGJI6/p4Mz nix-station-opencode"
  ];

  # Kernel hardening. Mainline sysctls only (no Debian-only keys); deliberately
  # conservative so containers and systemd keep working.
  boot.kernel.sysctl = {
    "kernel.kptr_restrict" = 2;
    "kernel.dmesg_restrict" = 1;
    "kernel.yama.ptrace_scope" = 1;
    "kernel.unprivileged_bpf_disabled" = 1;
    "net.core.bpf_jit_harden" = 2;
    "fs.protected_fifos" = 2;
    "fs.protected_regular" = 2;
    # Cilium's transparent DNS proxy marks the pod's DNS packet to the proxy,
    # which is routed via `lo` (local). With `net.ipv4.conf.all.src_valid_mark=1`
    # (set by the ProtonVPN WireGuard interface on .81) and `accept_local=0` on
    # the pod veth, that packet is dropped as a martian source, so toFQDNs/DNS
    # policy silently fails (cilium#46260). New lxc interfaces inherit this.
    "net.ipv4.conf.default.accept_local" = 1;
    # k3s/Cilium need IPv4 forwarding. NixOS's default (`all.forwarding=false`)
    # is re-applied by systemd-sysctl on activation; without a k3s restart that
    # leaves pod egress and hostPorts broken until a reboot. Pin it on.
    "net.ipv4.ip_forward" = 1;
    "net.ipv4.conf.all.forwarding" = lib.mkForce 1;
    "net.ipv4.conf.default.forwarding" = 1;
  };

  # Interfaces that existed before the sysctl was applied keep accept_local=0;
  # fix them when the config is activated (new ones get it from `default`).
  systemd.services.cilium-accept-local = {
    description = "Set accept_local=1 on existing lxc interfaces (Cilium DNS proxy)";
    after = [ "systemd-sysctl.service" ];
    wantedBy = [ "sysinit-reactivation.target" ];
    serviceConfig.Type = "oneshot";
    script = ''
      for i in /proc/sys/net/ipv4/conf/lxc*; do
        if [ -e "$i/accept_local" ]; then echo 1 > "$i/accept_local" || true; fi
      done
    '';
  };

  environment.systemPackages = with pkgs; [
    vim
    curl
    git
    htop
    tree
    wget
    age
    rclone
    openiscsi
    nfs-utils
    util-linux
    e2fsprogs
    xfsprogs
  ];

  # ---- Longhorn (distributed storage) prerequisites ----
  # open-iscsi initiator + iscsid; Longhorn attaches volumes over iSCSI.
  boot.kernelModules = [ "iscsi_tcp" "msr" "cpuid" ];
  services.openiscsi = {
    enable = true;
    name = "iqn.2026-10.dev.bismigel:${config.networking.hostName}";
  };
    # The iSCSI targets, the Longhorn instance-manager ports and the hostNetwork
    # exporters are NOT allowlisted here any more (2026-10-29).
    # `allowedTCPPorts` accepts from ANY source, so every device on the LAN - a
    # printer, a TV, a compromised container - could reach the iSCSI targets that
    # back the media pool and every Longhorn volume. They are scoped to the nodes
    # and the pod CIDR in `extraCommands` below, as 2379/2380 already were.
    networking.firewall.allowedTCPPorts = [ ];

  # Cilium native routing forwards pod traffic through the host. Trust the
  # veth interfaces and relax reverse-path filtering, as the Cilium NixOS
  # module does.
  networking.firewall.checkReversePath = false;
  networking.firewall.trustedInterfaces = [ "cni+" ];
    # etcd metrics relay (hostNetwork socat on :9101). This host runs the
    # iptables-based NixOS firewall, so extraCommands (not extraInputRules)
    # applies. Accept only the pod CIDR: Prometheus scrapes it, the LAN cannot.
    networking.firewall.extraCommands = ''
      # flannel SNATs cross-node pod egress to the node IP, so allow the three
      # nodes as well as the pod CIDR. Other LAN hosts stay blocked.
      iptables -I nixos-fw 1 -p tcp -m iprange --src-range 192.168.2.80-192.168.2.84 --dport 9101 -j nixos-fw-accept
      iptables -I nixos-fw 1 -p tcp -s 10.42.0.0/16 --dport 9101 -j nixos-fw-accept

      # Control-plane ports are node-to-node only (etcd) or nodes + pods
      # (kubelet, which metrics-server and the apiserver reach). They are
      # removed from allowedTCPPorts in each host file; 6443 stays on the LAN
      # because the admin kubectl talks to the API directly.
      iptables -I nixos-fw 1 -p tcp -m iprange --src-range 192.168.2.80-192.168.2.84 -m multiport --dports 2379,2380,10250 -j nixos-fw-accept
      iptables -I nixos-fw 1 -p tcp -s 10.42.0.0/16 -m multiport --dports 10250 -j nixos-fw-accept
  
      # iSCSI targets (Longhorn engines live here) - NODES ONLY. An open 3260 is
      # the port that lets something mount, and then corrupt, a volume.
      iptables -I nixos-fw 1 -p tcp -m iprange --src-range 192.168.2.80-192.168.2.84 \
        -m multiport --dports 3260,3261,3262,3263,3264 -j nixos-fw-accept
  
      # Longhorn instance-manager + the hostNetwork exporters (node-exporter,
      # kepler, Cilium agent/operator/envoy). Prometheus runs as a pod, so the
      # sources are the pod CIDR and the nodes themselves.
      iptables -I nixos-fw 1 -p tcp -s 10.42.0.0/16 \
        -m multiport --dports 9500,9501,9502,9503,9504,9505,9100,9102,9962,9963,9964 -j nixos-fw-accept
      iptables -I nixos-fw 1 -p tcp -m iprange --src-range 192.168.2.80-192.168.2.84 \
        -m multiport --dports 9500,9501,9502,9503,9504,9505,9100,9102,9962,9963,9964 -j nixos-fw-accept
    '';

    # Longhorn's containers nsenter into the host and call iscsiadm from PATH;
  # NixOS keeps it in /run/current-system/sw/bin, so expose it under /usr/bin too.
    # No LSM confinement beyond seccomp, and no kernel audit trail, until
    # 2026-10-29. auditd is the one that matters: it turns "the volumes
    # disappeared" into a timestamped record of who did it.
    # --- idle power -----------------------------------------------------------
    # sitaw-amd runs amd-pstate-epp, where the *governor* says "powersave" but the
    # energy/performance preference was `performance` - which pins the CPU's response
    # to any wakeup, and is why a 12-core box doing 4% work still drew ~8.9W of package
    # power (Kepler, 24h average, 2026-10-31). `power` tells the hardware to prefer the
    # lowest frequency that finishes the work.
    #
    # Deliberately not touching the governor: `powersave` with amd-pstate-epp already
    # means "use the EPP to decide", and forcing `performance`/`ondemand` here would
    # undo it.
    powerManagement.cpuFreqGovernor = "powersave";
    systemd.services.cpu-energy-preference = {
      description = "Bias CPU energy/performance preference toward idle power";
      wantedBy = [ "multi-user.target" ];
      # Re-applied at every boot because the setting lives in the CPU, not in a file.
      serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
      script = ''
        set -eu
        n=0
        for f in /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference; do
          [ -e "$f" ] || continue
          echo power > "$f" 2>/dev/null && n=$((n + 1)) || true
        done
        echo "cpu-energy-preference: set on $n cpu(s)"
      '';
    };

    security.auditd.enable = true;
    security.apparmor.enable = true;
    # enable = true turns the LSM on and loads NOTHING, which is worse than it
    # sounds: it looks like confinement until you count the profiles. Verified
    # 2026-10-29: /sys/kernel/security/apparmor/profiles held 0 entries, and a pod
    # asking for `appArmorProfile: {type: RuntimeDefault}` failed with
    # CreateContainerError because the runtime's default profile was not there to
    # apply. The upstream set (151 profiles: ping, tcpdump, man, chrome, buildah,
    # ...) gives the host binaries something to match. It is inert until a binary
    # matches a profile name, so loading it cannot break a running service.
    security.apparmor.packages = [ pkgs.apparmor-profiles ];
    # k8s `appArmorProfile: {type: RuntimeDefault}` does not invent a profile: it asks
    # containerd to apply `cri-containerd.apparmor.d`, which the runtime loads from
    # /etc/apparmor.d. Neither nixpkgs nor the k3s package ships it.
    #
    # THIS IS NOT SUFFICIENT. Verified 2026-10-29: the profile loads and is enforced
    # (`cri-containerd.apparmor.d (enforce)` in /sys/kernel/security/apparmor/profiles,
    # and `apparmor_parser -Q` accepts it), but a pod asking for RuntimeDefault still
    # fails with CreateContainerError and the runtime logs
    #   "apparmor spec opts: apparmor is not supported"
    # because NixOS's k3s containerd is built WITHOUT the apparmor tag:
    #   strings .../bin/containerd-shim-runc-v2 | grep -ci apparmor   -> 0
    # The shim that builds the runc spec is what drops the profile, so no manifest can
    # opt in until the runtime is rebuilt with `-tags apparmor` (or an external
    # containerd is used). The profile is kept because it is the other half of the
    # prerequisite and costs nothing while unrequested.
    #
    # Copied verbatim from containerd's own template
    # (github.com/containerd/containerd, contrib/apparmor/template.go), with the Go
    # template resolved for this cluster: Name=cri-containerd.apparmor.d,
    # DaemonProfile=unconfined, no abi line, no rootlesskit, and the base abstraction
    # import. `<tunables/global>` is prepended because the body uses @{PROC} and the
    # parser rejects it otherwise ("Found reference to variable PROC, but is never
    # declared"). Validated with `apparmor_parser -Q` against the apparmor-profiles
    # tree before it was committed.
    security.apparmor.policies."cri-containerd.apparmor.d".profile = ''
      #include <tunables/global>
      profile cri-containerd.apparmor.d flags=(attach_disconnected,mediate_deleted) {
        #include <abstractions/base>
        network,
        # Disallow AF_ALG (Linux kernel crypto API); see https://copy.fail/
        deny network alg,
        # Disallow AF_VSOCK to prevent host/guest communication.
        deny network vsock,
        capability,
        file,
        umount,
        # Host (privileged) processes may send signals to container processes.
        signal (receive) peer=unconfined,
        # runc may send signals to container processes.
        signal (receive) peer=runc,
        # crun may send signals to container processes.
        signal (receive) peer=crun,
        # Manager may send signals to container processes.
        signal (receive) peer=unconfined,
        # Container processes may send signals amongst themselves.
        signal (send,receive) peer=cri-containerd.apparmor.d,
        deny @{PROC}/* w,   # deny write for all files directly in /proc (not in a subdir)
        # deny write to files not in /proc/<number>/** or /proc/sys/**
        deny @{PROC}/{[^1-9/],[^1-9/][^0-9/],[^1-9s/][^0-9y/][^0-9s/],[^1-9/][^0-9/][^0-9/][^0-9/]*}/** w,
        deny @{PROC}/sys/[^k]** w,  # deny /proc/sys except /proc/sys/k* (effectively /proc/sys/kernel)
        deny @{PROC}/sys/kernel/{?,??,[^s][^h][^m]**} w,  # deny everything except shm* in /proc/sys/kernel/
        deny @{PROC}/sysrq-trigger rwklx,
        deny @{PROC}/kcore rwklx,
        deny mount,
        deny /sys/[^f]*/** wklx,
        deny /sys/f[^s]*/** wklx,
        deny /sys/fs/[^c]*/** wklx,
        deny /sys/fs/c[^g]*/** wklx,
        deny /sys/fs/cg[^r]*/** wklx,
        deny /sys/firmware/** rwklx,
        deny /sys/devices/virtual/powercap/** rwklx,
        deny /sys/kernel/security/** rwklx,
        # allow processes within the container to trace each other,
        # provided all other LSM and yama setting allow it.
        ptrace (trace,tracedby,read,readby) peer=cri-containerd.apparmor.d,
      }
    '';
    # Do not kill unconfined-but-confinable processes: k3s and Cilium are not
    # AppArmor-confined, and killing them to enforce a profile would take the
    # node down.
    security.apparmor.killUnconfinedConfinables = false;
  
  systemd.tmpfiles.rules = [
    "L+ /usr/bin/iscsiadm  - - - - ${pkgs.openiscsi}/bin/iscsiadm"
    "L+ /usr/sbin/iscsiadm - - - - ${pkgs.openiscsi}/bin/iscsiadm"
    "d /root/.config 0700 root root -"
  ];

  # R2 credential-backup config (creds + backup age recipient), rendered from
  # SOPS so it survives a rebuild instead of being hand-placed per host.
  sops.secrets."homelab_backup_env" = {
    path = "/root/.config/homelab-backup.env";
    owner = "root";
    mode = "0600";
  };

  # ---- Log retention -------------------------------------------------------
  # The journal is the large unbounded writer on / once the kubelet's container
  # log rotation is in place (that is configured per host with --kubelet-arg).
  # Cap it here so a chatty unit cannot grind the root filesystem down; 500M is
  # ~2 weeks of normal homelab output and leaves plenty of history for
  # `journalctl -u k3s` after an incident.
  services.journald.extraConfig = ''
    SystemMaxUse=500M
    SystemMaxFileSize=50M
    MaxRetentionSec=2week
    Compress=yes
  '';

  # ---- Update-staleness reminder ------------------------------------------
  # Patches are applied by hand with deploy-rs; nothing auto-updates. Warn via
  # the existing Alertmanager path when this host has gone 30 days without a new
  # generation, so a drifted package set is visible instead of silent.
  systemd.services.homelab-updates-check = {
    description = "Alert if the host has not been updated in 30 days";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeShellScript "homelab-updates-check" ''
        host=$(${pkgs.coreutils}/bin/cat /proc/sys/kernel/hostname)
        # NOT stat -L /run/current-system: that follows the symlink into the Nix
        # store, and Nix normalises store mtimes to the epoch (1) for
        # reproducibility. The check then computed 20752 days of staleness on a
        # host deployed minutes earlier and alerted on every run, on every host.
        # The profile symlink is re-pointed on each activation, so its OWN mtime
        # (stat without -L) is the deploy time we actually want.
        built=$(${pkgs.coreutils}/bin/stat -c %Y /nix/var/nix/profiles/system 2>/dev/null || echo 0)
        [ "$built" -gt 0 ] || exit 0
        age=$(( ( $(${pkgs.coreutils}/bin/date +%s) - built ) / 86400 ))
        if [ "$age" -ge 30 ]; then
          ${pkgs.curl}/bin/curl -fsS -m 10 -X POST -H 'Content-Type: application/json' \
            -d "[{\"labels\":{\"alertname\":\"SystemStale\",\"severity\":\"warning\",\"instance\":\"$host\"},\"annotations\":{\"summary\":\"$host has not been updated in $age days\"}}]" \
            http://127.0.0.1:30903/api/v2/alerts || true
        fi
      '';
    };
  };
  systemd.timers.homelab-updates-check = {
    description = "Weekly check for a stale deployment";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "weekly";
      Persistent = true;
      RandomizedDelaySec = "1h";
    };
  };

  system.stateVersion = "24.05";
}
