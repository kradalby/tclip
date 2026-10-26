# Run on Linux with KVM: nix build .#checks.x86_64-linux.headscale -L
{
  pkgs,
  headscale,
  tclip,
  tclipd,
}: let
  policy = sources:
    pkgs.writeText "tclip-policy.json" (builtins.toJSON {
      acls = [
        {
          action = "accept";
          src = sources;
          dst = ["server@:80"];
        }
      ];
    });
  allowed = policy ["alice@" "bob@"];
  restricted = policy ["alice@"];
  peer = {
    imports = [headscale.nixosModules.testkit-peer];
    environment.systemPackages = [pkgs.curl pkgs.jq tclip];
    virtualisation.memorySize = 512;
  };
in
  pkgs.testers.runNixOSTest {
    name = "tclip-headscale";
    globalTimeout = 1200;
    nodes = {
      headscale = {
        imports = [headscale.nixosModules.testkit];
        environment.systemPackages = [pkgs.curl];
      };
      server = {
        # Test-only root execution lets unchanged tsnet route across the VM's interfaces.
        systemd.services.tclip = {
          environment = {
            TSNET_CONTROL_URL = "http://headscale";
            DISABLE_HTTPS = "1";
            DATA_DIR = "/var/lib/tclip";
            HTTP_PORT = "8080";
            TS_NO_LOGS_NO_SUPPORT = "1";
          };
          serviceConfig = {
            ExecStart = "${tclipd}/bin/tclipd";
            User = "root";
            StateDirectory = "tclip";
            EnvironmentFile = "/run/tclip-auth";
          };
        };
        # tsnet chooses a UDP port dynamically.
        networking.firewall.allowedUDPPortRanges = [
          {
            from = 1024;
            to = 65535;
          }
        ];
        networking.firewall.allowedTCPPorts = [8080];
        environment.systemPackages = [pkgs.sqlite];
      };
      alice.imports = [peer];
      bob = {
        imports = [peer];
        systemd.services.tailscaled.environment.TS_DEBUG_ALWAYS_USE_DERP = "1";
      };
    };
    testScript = ''
      import json
      import shlex
      from datetime import timedelta
      from urllib.parse import urlparse

      T = timedelta(seconds=120)
      q = shlex.quote

      def request(machine, path, status=200, args="", base="http://paste"):
          code = machine.succeed(
              f"curl -sS --max-time 10 -o /tmp/body -w '%{{http_code}}' {args} {q(base + path)}"
          ).strip()
          body = machine.succeed("cat /tmp/body")
          assert code == str(status), (machine.name, path, code, body)
          return body

      def post(machine, name, content):
          url = request(machine, "/api/post", args=(
              f"-H 'Accept: text/plain' --data-urlencode {q('filename=' + name)} "
              f"--data-urlencode {q('content=' + content)}"
          )).strip()
          assert url.startswith("http://paste/paste/"), url
          return urlparse(url).path

      def sql(query):
          return server.succeed(f"sqlite3 -readonly /var/lib/tclip/data.db {q(query)}").strip()

      def nodes():
          return {
              n["givenName"]: (n["id"], sorted(n["ipAddresses"]))
              for n in json.loads(headscale.succeed("headscale nodes list -o json"))
          }

      start_all()
      server.wait_for_unit("multi-user.target")
      keys = {name: headscale.succeed(f"hs-authkey {name}").strip() for name in ("server", "alice", "bob")}
      headscale.succeed("headscale policy set -f ${allowed}")
      server.succeed(
          f"umask 077; printf '%s\\n' {q('TS_AUTHKEY=' + keys['server'])} > /run/tclip-auth; systemctl start tclip"
      )
      for machine in (alice, bob):
          machine.succeed(f"hs-join {q(keys[machine.name])}")
          machine.wait_until_succeeds("curl -fsS --max-time 5 http://paste/help", timeout=T)
      paste_ip = alice.succeed("tailscale ip -4 paste").strip()
      content = "hello from alice\nsecond line\n"

      with subtest("WhoIs identity, uploads and shared reads over IPv4 and IPv6"):
          assert "alice" in request(alice, "/", base=f"http://{paste_ip}")
          assert "bob" in request(bob, "/help")
          paste = post(alice, "alice.txt", content)
          assert request(bob, paste + "/raw") == content
          ipv6 = alice.succeed("tailscale ip -6 paste").strip()
          assert "bob" in request(bob, "/help", base=f"http://[{ipv6}]")
          assert request(bob, paste + "/raw", base=f"http://[{ipv6}]") == content
          assert "alice.txt" in request(bob, "/paste/list")
          assert "alice" in request(bob, paste)
          assert sql("SELECT u.login_name FROM pastes p JOIN users u ON p.user_id=u.id WHERE p.filename='alice.txt'") == "alice"
          alice.succeed("printf 'cli file\\n' > /tmp/cli.txt")
          cli_url = alice.succeed("timeout 15 tclip /tmp/cli.txt").strip()
          assert request(bob, urlparse(cli_url).path + "/raw") == "cli file\n"
          stdin_url = bob.succeed("printf 'cli stdin' | timeout 15 tclip -n stdin.txt").strip()
          assert request(alice, urlparse(stdin_url).path + "/raw") == "cli stdin"
          assert request(bob, paste + "/dl", args="-D /tmp/headers") == content
          bob.succeed("grep -i 'Content-Disposition: attachment; filename=\"alice.txt\"' /tmp/headers")

      with subtest("ordinary users can delete their own pastes but not another user's"):
          delete = "/api/delete/" + paste.split("/")[-1]
          assert f'href="{delete}"' in request(alice, paste)
          assert f'href="{delete}"' not in request(bob, paste)
          assert "can only delete your pastes" in request(bob, delete, 403)
          assert request(bob, paste + "/raw") == content
          own = post(bob, "bob.txt", "bob can delete this")
          request(alice, "/api/delete/" + own.split("/")[-1], 403)
          request(bob, "/api/delete/" + own.split("/")[-1], 307)
          assert sql("SELECT count(*) FROM pastes WHERE filename='bob.txt'") == "0"

      with subtest("direct and forced-DERP application traffic"):
          alice.wait_until_succeeds("tailscale ping -c 1 --timeout 3s paste", timeout=T)
          alice.succeed("tailscale status --json | jq -e '.Peer[] | select(.HostName == \"paste\") | .CurAddr != \"\"'")
          bob.wait_until_succeeds("tailscale ping --until-direct=false -c 1 --timeout 3s paste | grep -F 'via DERP(headscale)'", timeout=T)
          for machine in (alice, bob):
              payload = (machine.name + " transport\n") * 1024
              path = post(machine, machine.name + "-transport.txt", payload)
              assert request(machine, path + "/raw") == payload

      with subtest("live ACL denial and recovery keep allowed application traffic working"):
          headscale.succeed("headscale policy set -f ${restricted}")
          denied = f"curl -fsS --max-time 3 http://{paste_ip}{paste}/raw"
          bob.wait_until_fails(denied, timeout=T)
          assert request(alice, paste + "/raw") == content
          bob.fail(denied)
          count = sql("SELECT count(*) FROM pastes")
          bob.fail(f"timeout 10 tclip -target http://{paste_ip} /etc/hostname")
          assert sql("SELECT count(*) FROM pastes") == count
          control = post(alice, "allowed-during-denial.txt", "still writable")
          assert request(alice, control + "/raw") == "still writable"
          headscale.succeed("headscale policy set -f ${allowed}")
          bob.wait_until_succeeds(denied, timeout=T)
          assert request(bob, paste + "/raw") == content
          recovered = post(bob, "recovered.txt", "writable again")
          assert request(alice, recovered + "/raw") == "writable again"

      with subtest("public HTTP serves pastes without exposing mutation routes"):
          public = "http://server:8080"
          assert request(headscale, paste + "/raw", base=public) == content
          count = sql("SELECT count(*) FROM pastes")
          assert "Not found" in request(headscale, "/api/post", base=public, args="-d filename=public.txt -d content=public")
          assert "Not found" in request(headscale, delete, base=public)
          assert sql("SELECT count(*) FROM pastes") == count
          assert request(alice, paste + "/raw") == content

      with subtest("restart preserves content and tsnet enrollment without an auth key"):
          before = nodes()
          assert set(before) == {"paste", "alice", "bob"}
          server.succeed("systemctl stop tclip; : > /run/tclip-auth; systemctl start tclip")
          alice.wait_until_succeeds(f"curl -fsS --max-time 5 http://{paste_ip}{paste}/raw", timeout=T)
          assert request(bob, paste + "/raw") == content
          assert "alice" in request(alice, "/help")
          assert nodes() == before
          request(bob, delete, 403)
          request(alice, delete, 307)
          assert sql("SELECT count(*) FROM pastes WHERE filename='alice.txt'") == "0"
          server.succeed("systemctl restart tclip")
          alice.wait_until_succeeds("curl -fsS --max-time 5 http://paste/help", timeout=T)
          assert sql("SELECT count(*) FROM pastes WHERE filename='alice.txt'") == "0"
    '';
  }
