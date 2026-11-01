# Long-running network services must not be able to give up permanently.
#
# Two services on this estate failed this way on 2026-11-01, for the same reason:
#
#   cloudflared-tunnel-8dcc83bd...  failed at 06:01:12, restarted 6 times in under
#     a second while the network was mid-change, then systemd's start limit
#     ("Start request repeated too quickly") latched it *failed*. It stayed dead
#     for seven hours and the public edge ran on a single connector.
#
#   wireguard-proton0  refused to start (correctly - "eno1 never became usable for
#     176.113.74.82 via 192.168.2.1 - refusing to blackhole the node") and then
#     never retried. Forty minutes with no egress, which became no DNS, which
#     became forty pods in ImagePullBackOff.
#
# Neither was a bug in the service. Both were **systemd's default restart policy
# meeting a transient boot-time condition**: a service that fails fast and often
# gets rate-limited into permanence, and a oneshot-shaped unit has no restart at
# all. A network service that a reboot cannot recover, and that nothing pages
# about, is a trapdoor.
#
# So: retry forever with a slow backoff, and never latch. `StartLimitIntervalSec = 0`
# disables the rate limiter; `Restart=on-failure` retries a failed start; the
# 15 s spacing keeps a genuinely broken service from spinning the CPU while a
# transient one recovers within a minute or two.
#
# What this does NOT do: make a misconfigured service work. It only removes the
# state where a service that *would* work is left dead because it tried too early.
{ lib, ... }:
{
  # Units are matched by name, so this covers whatever the host defines.
  systemd.services = lib.genAttrs
    [
      "cloudflared-tunnel-8dcc83bd-eb95-4c0d-8f71-b92a27d37649"
      "wireguard-proton0"
    ]
    (_: {
      unitConfig = {
        # 0 = no rate limit. Without this, `StartLimitBurst` (default 5) in
        # `StartLimitIntervalSec` (default 10 s) turns a burst of boot-time
        # failures into a permanent one.
        StartLimitIntervalSec = "0";
      };
      serviceConfig = {
        Restart = "on-failure";
        # Not 1s: a service failing because the gateway's ARP is not ready needs
        # seconds, not milliseconds, and a tight loop hides the real cause in the
        # journal while burning restarts.
        RestartSec = "15s";
        # A restart must not be considered a fresh "start" for the rate limiter.
        StartLimitBurst = 0;
      };
    });
}
