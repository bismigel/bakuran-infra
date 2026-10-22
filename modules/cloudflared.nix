{ ... }:

# cloudflared pin — Cloudflare advisory of 2026-10-19.
#
# Eight eMudhra intermediate certificates were compromised (weak private keys),
# so an attacker can forge a certificate for any domain that chains to a
# trusted root. Cloudflare mitigated its own edge and published cloudflared
# 2026.10.2 on 2026-10-20 09:15 UTC; customers were told to upgrade their
# connectors.
#
# nixpkgs 25.11 still packages cloudflared 2025.11.1, which is what both
# connectors here were running (verified from the Cloudflare API:
# client_version 2025.11.1 on all eight connections). cloudflared is a Go
# binary, and Go's TLS stack does not check certificate revocation by default,
# so an old build will happily accept a forged chain — the version is the
# mitigation, not a nicer trust store.
#
# This overlay pins the vendor's release binary, hashed, until nixpkgs ships
# 2026.10.2 or newer. Delete this module once
# `nix shell nixpkgs#cloudflared -c cloudflared --version` reports >= 2026.10.2.
{
  nixpkgs.overlays = [
    (final: prev: {
      cloudflared = prev.stdenvNoCC.mkDerivation rec {
        pname = "cloudflared";
        version = "2026.10.2";

        src = prev.fetchurl {
          url = "https://github.com/cloudflare/cloudflared/releases/download/${version}/cloudflared-linux-amd64";
          sha256 = "35fbdd2beb378436c7da377d7358cea8e33f9c94a6705d1d8036bf9b0d6d8005";
        };

        # Already a compiled binary: install it untouched rather than letting
        # fixup strip or patch the vendor artefact.
        dontUnpack = true;
        dontBuild = true;
        dontStrip = true;

        installPhase = ''
          runHook preInstall
          install -Dm755 $src $out/bin/cloudflared
          runHook postInstall
        '';

        meta = {
          description = "Cloudflare Tunnel client (pinned upstream release)";
          homepage = "https://github.com/cloudflare/cloudflared";
          license = prev.lib.licenses.asl20;
          platforms = [ "x86_64-linux" ];
          mainProgram = "cloudflared";
        };
      };
    })
  ];
}
