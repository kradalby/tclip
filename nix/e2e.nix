# Run on Linux with KVM: nix build .#e2e -L
{
  pkgs,
  headscale,
  tclip,
  tclipd,
}: let
  policy = sources:
    pkgs.writeText "tclip-policy.json" (
      builtins.toJSON {
        tagOwners."tag:client" = ["alice@"];
        acls = [
          {
            action = "accept";
            src = sources;
            dst = ["server@:80,443"];
          }
        ];
      }
    );
  allowed = policy [
    "alice@"
    "bob@"
    "tag:client"
  ];
  restricted = policy [
    "alice@"
    "tag:client"
  ];
  peer = {
    imports = [headscale.nixosModules.testkit-peer];
    environment.systemPackages = [
      pkgs.curl
      pkgs.jq
      tclip
    ];
    virtualisation.memorySize = 512;
  };
  service = pkgs.replaceVars ../run/portable-service/tclip.service.in {inherit tclipd;};
in
  pkgs.testers.runNixOSTest {
    name = "tclip-headscale";
    globalTimeout = 1200;
    nodes = {
      headscale = {
        imports = [headscale.nixosModules.testkit];
        environment.systemPackages = [pkgs.jq];
        # Advertise CertDomains; cached certificates avoid public DNS/ACME.
        services.headscale.settings.dns = {
          certificates.enabled = true;
          challenge.provider = {
            name = "rfc2136";
            server = "127.0.0.1:53";
            key_name = "fixture";
            key_alg = "hmac-sha256";
            key = "c2VjcmV0";
          };
        };
      };
      server = {
        # Reuse the production unit, including DynamicUser and StateDirectory.
        systemd.packages = [
          (pkgs.runCommand "tclip-unit" {} ''
            mkdir -p $out/lib/systemd/system
            cp ${service} $out/lib/systemd/system/tclip.service
          '')
        ];
        systemd.services.tclip = {
          overrideStrategy = "asDropin";
          environment = {
            TSNET_CONTROL_URL = "http://headscale";
            DISABLE_HTTPS = "1";
            TSNET_DISABLE_NETNS = "1";
            TS_NO_LOGS_NO_SUPPORT = "1";
            TSNET_VERBOSE = "1";
            HTTP_PORT = "8080";
          };
          serviceConfig.EnvironmentFile = "/run/tclip-auth";
        };
        # tsnet chooses a UDP port dynamically. The public HTTP listener is deliberate.
        networking.firewall.allowedUDPPortRanges = [
          {
            from = 1024;
            to = 65535;
          }
        ];
        networking.firewall.allowedTCPPorts = [8080];
        environment.systemPackages = [
          pkgs.curl
          pkgs.openssl
          pkgs.sqlite
        ];
      };
      alice.imports = [peer];
      relay = {
        imports = [peer];
        systemd.services.tailscaled.environment.TS_DEBUG_ALWAYS_USE_DERP = "1";
      };
      bob.imports = [peer];
      tagged.imports = [peer];
      tagged2.imports = [peer];
    };
    testScript = ''
      import json
      import shlex
      from urllib.parse import urlparse
      from datetime import timedelta

      T = timedelta(seconds=120)
      q = shlex.quote

      def request(machine, path, status=200, args="", base="http://paste"):
          if base.startswith("https://"):
              args += " --cacert /tmp/app.crt"
          code = machine.succeed(
              f"curl -sS --max-time 10 -o /tmp/body -w '%{{http_code}}' {args} {q(base + path)}"
          ).strip()
          assert code == str(status), (machine.name, path, code, machine.succeed("cat /tmp/body"))
          return machine.succeed("cat /tmp/body")

      def post(machine, name, content, base="http://paste"):
          url = request(machine, "/api/post", base=base, args=(
              f"-H 'Accept: text/plain' --data-urlencode {q('filename=' + name)} "
              f"--data-urlencode {q('content=' + content)}"
          )).strip()
          assert url.startswith(base + "/paste/"), url
          return urlparse(url).path

      def sql(query):
          return server.succeed(f"sqlite3 /var/lib/private/tclip/data/data.db {q(query)}").strip()

      def nodes():
          return json.loads(headscale.succeed("headscale nodes list -o json"))

      start_all()
      server.wait_for_unit("multi-user.target")
      server_key = headscale.succeed("hs-authkey server").strip()
      alice_key = headscale.succeed("hs-authkey alice").strip()
      bob_key = headscale.succeed("hs-authkey bob").strip()
      headscale.succeed("headscale policy set -f ${allowed}")
      with subtest("tclipd rejects an invalid auth key before serving the tailnet"):
          server.succeed("umask 077; printf 'TS_AUTHKEY=tskey-auth-invalid\\n' > /run/tclip-auth; systemctl start tclip")
          server.wait_until_succeeds("journalctl -u tclip -o cat | grep -F 'invalid pre auth key'", timeout=T)
          assert not [n for n in nodes() if n['givenName'] == 'paste']
          headscale.succeed("HEADSCALE_CLI_TIMEOUT=60s headscale health")
          server.succeed("systemctl stop tclip")
      server.succeed(f"umask 077; printf '%s\\n' TS_AUTHKEY={q(server_key)} > /run/tclip-auth")
      server.succeed("systemctl start tclip")
      alice.succeed(f"hs-join {alice_key}")
      relay.succeed(f"hs-join {alice_key}")
      bob.succeed(f"hs-join {bob_key}")
      tagged_key = headscale.succeed("hs-authkey alice --tags tag:client").strip()
      tagged.succeed(f"hs-join {tagged_key}")
      tagged2.succeed(f"hs-join {tagged_key}")
      alice.wait_until_succeeds("curl -fsS --max-time 5 http://paste/help", timeout=T)
      paste_ip = alice.succeed("tailscale ip -4 paste").strip()

      with subtest("production service runs unprivileged and keeps private state"):
          pid = server.succeed("systemctl show tclip -p MainPID --value").strip()
          server.succeed(f"test $(awk '/^Uid:/ {{print $2}}' /proc/{pid}/status) -ne 0")
          server.succeed(f"grep -E '^CapEff:[[:space:]]+0+$' /proc/{pid}/status")
          server.succeed("test $(stat -c %a /var/lib/private/tclip/data) = 700")
          server.succeed("test $(stat -c %a /var/lib/private/tclip/data/tsnet) = 700")

      with subtest("WhoIs identity, shared reads, CLI and form uploads"):
          assert "alice" in request(alice, "/")
          assert "alice" in request(alice, "/", base=f"http://{paste_ip}")
          assert "bob" in request(bob, "/help")
          paste = post(alice, "alice.txt", "hello from alice\nsecond line\n")
          assert request(bob, paste + "/raw") == "hello from alice\nsecond line\n"
          ipv6 = alice.succeed("tailscale ip -6 paste").strip()
          assert "bob" in request(bob, "/help", base=f"http://[{ipv6}]")
          assert request(bob, paste + "/raw", base=f"http://[{ipv6}]") == "hello from alice\nsecond line\n"
          assert "alice.txt" in request(bob, "/paste/list")
          assert "alice" in request(bob, paste)
          assert sql("SELECT u.login_name FROM pastes p JOIN users u ON p.user_id=u.id WHERE p.filename='alice.txt'") == "alice"
          alice.succeed("printf 'cli file\\n' > /tmp/cli.txt")
          cli_url = alice.succeed("timeout 15 tclip /tmp/cli.txt").strip()
          assert request(relay, urlparse(cli_url).path + "/raw") == "cli file\n"
          stdin_url = relay.succeed("printf 'cli stdin' | timeout 15 tclip -n stdin.txt").strip()
          assert request(alice, urlparse(stdin_url).path + "/raw") == "cli stdin"
          request(bob, paste + "/dl", args="-D /tmp/headers")
          bob.succeed("grep -i 'Content-Disposition: attachment; filename=\"alice.txt\"' /tmp/headers")
          assert bob.succeed("cat /tmp/body") == "hello from alice\nsecond line\n"
          multipart = request(bob, "/api/post", args="-H 'Accept: text/plain' -F filename=multipart.txt -F content=multipart")
          assert request(alice, urlparse(multipart).path + "/raw") == "multipart"
          request(bob, "/api/post", 303, args="-d filename=browser.txt -d content=browser -D /tmp/headers")
          bob.succeed("grep -i 'Location: http://paste/paste/' /tmp/headers")

      with subtest("owner-only deletion uses WhoIs, not spoofed headers"):
          assert "can only delete your pastes" in request(
              bob, "/api/delete/" + paste.split("/")[-1], 403,
              args=f"-H 'Tailscale-User-Login: alice' -H 'X-Forwarded-For: {alice.succeed('tailscale ip -4').strip()}'"
          )
          assert request(bob, paste + "/raw") == "hello from alice\nsecond line\n"
          own = post(bob, "bob.txt", "bob can delete this")
          request(bob, "/api/delete/" + own.split("/")[-1], 307)
          assert sql("SELECT count(*) FROM pastes WHERE filename='bob.txt'") == "0"
          # A second device owned by Alice can delete Alice's paste.
          same_user = post(alice, "same-user.txt", "shared identity")
          request(relay, "/api/delete/" + same_user.split("/")[-1], 307)

      with subtest("tagged nodes have distinct authors and deletion ownership"):
          tag_paste = post(tagged, "tagged.txt", "tag-owned")
          assert "tagged node tagged: tag:client" in request(alice, tag_paste)
          assert sql("SELECT u.login_name FROM pastes p JOIN users u ON p.user_id=u.id WHERE p.filename='tagged.txt'") == "tagged"
          tag_other = post(tagged2, "tagged2.txt", "other tag-owned")
          request(tagged2, "/api/delete/" + tag_paste.split("/")[-1], 403)
          request(alice, "/api/delete/" + tag_paste.split("/")[-1], 403)
          assert request(tagged2, tag_paste + "/raw") == "tag-owned"
          request(tagged2, "/api/delete/" + tag_other.split("/")[-1], 307)
          request(tagged, "/api/delete/" + tag_paste.split("/")[-1], 307)

      with subtest("direct and forced-DERP application traffic"):
          alice.wait_until_succeeds("tailscale ping -c 1 --timeout 3s paste", timeout=T)
          alice.succeed("tailscale status --json | jq -e '.Peer[] | select(.HostName == \"paste\") | .CurAddr != \"\"'")
          relay.wait_until_succeeds("tailscale ping --until-direct=false -c 1 --timeout 3s paste | grep -F 'via DERP(headscale)'", timeout=T)
          for machine in (alice, relay):
              content = (machine.name + " transport\n") * 1024
              path = post(machine, machine.name + "-transport.txt", content)
              assert request(machine, path + "/raw") == content

      with subtest("live ACL denial with concurrent allowed-operation control"):
          headscale.succeed("headscale policy set -f ${restricted}")
          denied = f"curl -fsS --max-time 3 http://{paste_ip}{paste}/raw"
          bob.wait_until_fails(denied, timeout=T)
          assert request(alice, paste + "/raw") == "hello from alice\nsecond line\n"
          bob.fail(denied)
          bob.fail(f"timeout 10 tclip -target http://{paste_ip} /etc/hostname")
          control = post(relay, "allowed-during-denial.txt", "still writable")
          assert request(alice, control + "/raw") == "still writable"
          headscale.succeed("headscale policy set -f ${allowed}")
          bob.wait_until_succeeds(denied, timeout=T)

      with subtest("public HTTP only exposes read routes and cannot forge WhoIs"):
          public = "http://server:8080"
          author = '<span class="dark:text-gray-300">alice</span>'
          assert author in request(headscale, paste, base=public)
          assert request(headscale, paste + "/raw", base=public) == "hello from alice\nsecond line\n"
          count = sql("SELECT count(*) FROM pastes")
          for route in ("/api/post", "/api/delete/" + paste.split("/")[-1], "/help"):
              args = "-H 'Tailscale-User-Login: alice'"
              if route == "/api/post":
                  args += " -d filename=forged -d content=forged"
              body = request(headscale, route, base=public, args=args)
              assert "Not found" in body
          request(headscale, "/paste/list", 500, base=public)
          assert sql("SELECT count(*) FROM pastes") == count
          assert request(alice, paste + "/raw") == "hello from alice\nsecond line\n"
          headscale.fail("curl -fsS --max-time 3 http://server:80/help")
          headscale.succeed("curl -fsS --max-time 3 http://server:8080/")

      with subtest("malformed requests fail without stopping service"):
          request(alice, "/api/post", 400, args="-H 'Content-Type: text/plain' -d invalid")
          request(alice, "/api/post", 400, args="-d unrelated=value")
          request(alice, paste, 405, args="-X POST")
          request(alice, "/api/delete/" + paste.split("/")[-1], 405, args="-X POST")
          request(alice, "/paste/nonexistent", 500)
          assert request(alice, paste + "/raw") == "hello from alice\nsecond line\n"

      with subtest("established direct traffic survives a control server outage"):
          alice.wait_until_succeeds("tailscale ping -c 1 --timeout 3s paste", timeout=T)
          headscale.succeed("systemctl stop headscale")
          headscale.fail("curl -fsS --max-time 3 http://localhost/health")
          try:
              offline = post(alice, "offline.txt", "control unavailable")
              assert request(alice, offline + "/raw") == "control unavailable"
          finally:
              headscale.succeed("systemctl start headscale")
              headscale.succeed("HEADSCALE_CLI_TIMEOUT=60s headscale health")
          relay.wait_until_succeeds("tailscale ping --until-direct=false -c 1 --timeout 3s paste | grep -F 'via DERP(headscale)'", timeout=T)
          assert request(relay, offline + "/raw") == "control unavailable"

      with subtest("restart preserves SQLite and tsnet identity without an auth key"):
          before = nodes()
          server.succeed("systemctl stop tclip; printf 'HIDE_FUNNEL_USERS=1\\n' > /run/tclip-auth; systemctl start tclip")
          alice.wait_until_succeeds(f"curl -fsS --max-time 5 http://{paste_ip}{paste}/raw", timeout=T)
          assert request(relay, paste + "/raw") == "hello from alice\nsecond line\n"
          assert author not in request(headscale, paste, base="http://server:8080")
          assert "alice" in request(alice, "/help")
          after = nodes()
          assert {(n['id'], n['ipAddresses'][0]) for n in before} == {(n['id'], n['ipAddresses'][0]) for n in after}
          request(bob, "/api/delete/" + paste.split("/")[-1], 403)
          request(alice, "/api/delete/" + paste.split("/")[-1], 307)
          server.succeed("systemctl restart tclip")
          alice.wait_until_succeeds("curl -fsS --max-time 5 http://paste/help", timeout=T)
          assert sql("SELECT count(*) FROM pastes WHERE filename='alice.txt'") == "0"

      with subtest("real application TLS with a cached certificate and trusted peer"):
          state = "/var/lib/private/tclip/data/tsnet"
          server.succeed(f"mkdir -p {state}/certs")
          server.succeed(
              f"openssl req -x509 -newkey rsa:2048 -nodes -days 30 -subj /CN=paste.tailnet "
              f"-addext subjectAltName=DNS:paste.tailnet -keyout {state}/certs/paste.tailnet.key "
              f"-out {state}/certs/paste.tailnet.crt"
          )
          server.succeed(f"chown --reference={state} {state}/certs {state}/certs/*; chmod 600 {state}/certs/*")
          cert = server.succeed(f"cat {state}/certs/paste.tailnet.crt")
          for machine in (alice, relay, bob):
              machine.succeed(f"printf %s {q(cert)} > /tmp/app.crt")
          # Flags override the initial HTTP-only environment; exercise both configuration forms.
          server.succeed("mkdir -p /run/systemd/system/tclip.service.d")
          dropin = f"[Service]\nEnvironment=SSL_CERT_FILE={state}/certs/paste.tailnet.crt\nExecStart=\nExecStart=${tclipd}/bin/tclipd --control-url=http://headscale --disable-https=false\n"
          server.succeed(f"printf %s {q(dropin)} > /run/systemd/system/tclip.service.d/https.conf")
          server.succeed("systemctl daemon-reload; systemctl restart tclip")
          tls = "https://paste.tailnet"
          alice.wait_until_succeeds(f"curl -fsS --max-time 5 --cacert /tmp/app.crt {tls}/help", timeout=T)
          code, _ = alice.execute(f"curl -fsS --max-time 5 {tls}/help")
          assert code == 60, code  # The fixture must not bypass certificate verification.
          alice.wait_until_succeeds("tailscale ping -c 1 --timeout 3s paste", timeout=T)
          relay.wait_until_succeeds("tailscale ping --until-direct=false -c 1 --timeout 3s paste | grep -F 'via DERP(headscale)'", timeout=T)
          for machine in (alice, relay):
              secured = post(machine, "secure.txt", "TLS via " + machine.name, base=tls)
              assert request(machine, secured + "/raw", base=tls) == "TLS via " + machine.name
              request(bob, "/api/delete/" + secured.split("/")[-1], 403, base=tls)
              assert request(bob, secured + "/raw", base=tls) == "TLS via " + machine.name
              request(machine, "/api/delete/" + secured.split("/")[-1], 307, base=tls)
          headscale.succeed("headscale policy set -f ${restricted}")
          denied_tls = f"curl -fsS --max-time 3 --cacert /tmp/app.crt --resolve paste.tailnet:443:{paste_ip} {tls}/help"
          bob.wait_until_fails(denied_tls, timeout=T)
          request(alice, "/help", base=tls)
          bob.fail(denied_tls)
          headscale.succeed("headscale policy set -f ${allowed}")
          bob.wait_until_succeeds(denied_tls, timeout=T)
          server.succeed("systemctl restart tclip")
          relay.wait_until_succeeds(f"curl -fsS --max-time 5 --cacert /tmp/app.crt {tls}/help", timeout=T)

      with subtest("Funnel fails closed without its node capability"):
          request(alice, "/help", base=tls)
          denied_funnel = dropin.replace("--disable-https=false", "--disable-https=false --use-funnel") + "Restart=no\n"
          server.succeed(f"printf %s {q(denied_funnel)} > /run/systemd/system/tclip.service.d/https.conf")
          server.succeed("systemctl daemon-reload; systemctl restart tclip")
          server.wait_until_succeeds("test $(systemctl show tclip -p ExecMainStatus --value) = 1", timeout=T)
          server.succeed("journalctl -u tclip -o cat | grep -F 'node attribute not set'")
          server.succeed(f"printf %s {q(dropin)} > /run/systemd/system/tclip.service.d/https.conf")
          server.succeed("systemctl daemon-reload; systemctl restart tclip")
          alice.wait_until_succeeds(f"curl -fsS --max-time 5 --cacert /tmp/app.crt {tls}/help", timeout=T)

      with subtest("invalid authentication cannot join, valid key recovers"):
          tagged2.succeed("tailscale logout")
          tagged2.fail("tailscale up --timeout=10s --login-server http://headscale --auth-key tskey-auth-invalid")
          tagged2.fail(f"curl -fsS --max-time 3 http://{paste_ip}/help")
          request(alice, "/help")
          tagged2.succeed(f"hs-join {tagged_key}")
          tagged2.wait_until_succeeds("curl -fsS --max-time 5 http://paste/help", timeout=T)
    '';
  }
