# tclip

[![status: experimental](https://img.shields.io/badge/status-experimental-blue)](https://tailscale.com/kb/1167/release-stages/#experimental)

A self-hostable pastebin for your tailnet. It can store an infinite\*
number of pastes.

## Development

1. Install Nix
2. Enable flakes
3. `nix develop`

You can then test your changes to tclip by running `go run
./cmd/tclipd` or `go run ./cmd/tclip` as appropriate.

Note that for the first run of `./cmd/tclipd`, you _must_ set
either the `TS_AUTHKEY` environment variable, or run it with
`--tsnet-verbose` to get the login URL for Tailscale.

## Building for prod

The web server:

```
nix build .#tclipd
```

The docker image:

```
nix develop --command -- mkctr --gopaths="./cmd/tclipd:/bin/tclipd" --tags="latest" --base="gcr.io/distroless/static" --repos=tclip --ldflags="-w -s" --target=local --push  -- /bin/tclipd
docker run tclip
```

The portable service image:

```
nix build .#portable-service
```

## Configuration

These configuration options are available as command-line flags and
environment variables. All of them are optional.

| Command-line flag       | Environment variable   | Default value               | Description                                                                                                  |
| ----------------------- | ---------------------- | --------------------------- | ------------------------------------------------------------------------------------------------------------ |
| `-hostname`             | `TSNET_HOSTNAME`       | `paste`                     | The hostname to use on your tailnet.                                                                         |
| `-data-location`        | `DATA_DIR`             | `~/.config/tailscale/paste` | Where program data is stored.                                                                                |
| `-tsnet-verbose`        | `TSNET_VERBOSE`        | `false`                     | If set, tsnet will log verbosely to stderr.                                                                  |
| `-use-funnel`           | `USE_FUNNEL`           | `false`                     | If set, expose individual pastes to the public internet with [Funnel](https://tailscale.com/kb/1223/funnel). |
| `-hide-funnel-users`    | `HIDE_FUNNEL_USERS`    | `false`                     | If set, don't display the username and profile picture of the user who created the paste in funneled pastes. |
| `-http-port`            | `HTTP_PORT`            | unset                       | If set, expose individual pastes on a HTTP server running on the given port.                                 |
| `-control-url`          | `TSNET_CONTROL_URL`    | unset                       | If set, a custom control server to use, e.g. for Headscale users.                                            |
| `-disable-netns`         | `TSNET_DISABLE_NETNS`   | `false`                     | If set, use OS routing instead of tsnet interface binding on unprivileged multihomed hosts. Leave unset when routing through a host Tailscale interface could cause a loop. |
| `-disable-https`        | `DISABLE_HTTPS`        | `false`, becomes `true` when HTTPS is unavailable on the tailnet.                     | If set, disable serving on HTTPS, even if HTTPS serving is available.                               |
| `-enable-line-numbers`  | `ENABLE_LINE_NUMBERS`  | `false`                     | If set, enable line numbers being shown when viewing a paste.                                                |
| `-enable-word-wrap`     | `ENABLE_WORD_WRAP`     | `false`                     | If set, allows lines to break and wrap to the following line.                                                |

## Deploying

There are several options you can take to deploy tclip. The most
basic deployment method is to use [fly.io](https://fly.io), but we
offer a few options so that you can make the decision that is right
for you.

### Prerequisites

In order to deploy this service, you will need to get an authkey from
[the admin panel](https://login.tailscale.com/admin/settings/keys). It
is a good idea to associate this with the tag `tag:service` or its own
`tag:tclip`. Please also do not set the `ephemeral` tag as that
will destroy the node when the service shuts down.

Your authkey should start with `tskey-auth`.

You will need to have Magic DNS enabled.

### fly.io

In one of your infrastructure management GitHub repositories, create a
folder for tclip and then copy the following
[`fly.toml`](https://fly.io/docs/reference/configuration/) template
into that folder.

```toml
app = "FLY_APP_NAME"

[build]
image = "ghcr.io/tailscale-dev/tclip:latest"

[deploy]
strategy = "immediate"

[env]
DATA_DIR = "/data"

[mounts]
source = "tclip_data"
destination = "/data"
```

Replace `FLY_APP_NAME` with a name such as `yourorg-tclip` and
then run these commands with [the `flyctl` command](https://fly.io/docs/hands-on/install-flyctl/):

```console
$ flyctl apps create FLY_APP_NAME
$ flyctl volumes create tclip_data
$ flyctl secrets set TS_AUTHKEY=<key>
$ flyctl deploy
```

You should be able to open the app at [http://paste](http://paste) and
paste to your heart's content.

#### Updating

Run `flyctl deploy` to update the service.

### Normal Docker

To run this service in Docker, run the following command:

```
docker run \
  -d \
  -v /var/lib/tclip:/data \
  -e DATA_DIR=/data \
  -e TS_AUTHKEY=<key> \
  -n tclip \
  --restart always \
  ghcr.io/tailscale-dev/tclip:latest
```

#### Updating

Every so often you should pull a new version of tclip and
recreate the container:

```
docker pull ghcr.io/tailscale-dev/tclip:latest
docker rm -f tclip
```

Then run the above command to recreate the container.

#### Backups

Add the path `/var/lib/tclip` to your backup program of choice.

### Systemd portable service

systemd has a mechanism for [portable
service](https://systemd.io/PORTABLE_SERVICES/) which are like Docker
images mixed with systemd unit configurations. This allows you to
install tclip on any Linux distribution with systemd (and the
`portablectl` command, install `systemd-container` to get this package
on Ubuntu). This lets you view tclip logs with `journalctl` and
manage it like any other systemd service.

You can download the portable service image from CI by looking at the
[recently finished
builds](https://github.com/tailscale-dev/tclip/actions?query=is%3Asuccess+branch%3Amain),
clicking on the most recent one, and downloading the
`portable-service` artifact. This will get you a zipfile that contains
a single `.raw` file. Copy this `.raw` file to `/var/lib/portable` on
your target server. Then run `portablectl list` to get a list of
available portable services:

```console
$ portablectl list
NAME                       TYPE RO  CRTIME                      MTIME                       USAGE STATE
tclip_0.1.0-20230116 raw  yes Mon 2023-01-16 16:49:58 UTC Mon 2023-01-16 16:53:59 UTC 14.8M detached
```

Copy the name of the `tclip` service including the
auto-generated version number to your clipboard (for example:
`tclip_0.1.0-20230116`) and pass that to `portablectl attach`:

```console
$ sudo portablectl attach tclip_0.1.0-20230116
```

Next, create the folder `/etc/systemd/system/tclip.service.d`
and create the file `10-ts-auth-key.conf` in it with the following
contents (be sure to replace `<key>` with your tailnet authkey):

```systemd
# /etc/systemd/system/tclip.service.d/10-ts-authkey.conf
[Service]
Environment=TS_AUTHKEY=<key>
```

Finally, enable `tclip.service` and start it with `systemctl
enable --now`:

```console
$ sudo systemctl enable --now tclip.service
```

Wait a moment for it to connect to Tailscale and then check on it with
`tailscale status`. Your new node named `paste` should show up in your
tailnet.

#### Updating

To update tclip, first detach the portable service using `portablectl
detach` after finding the list with `portablectl list`. Then delete
the correlating `.raw` file in `/var/lib/portables`. Download a new
one in its place and re-attach and re-enable the service.

#### Backups

Add the path `/var/lib/private/tclip` to your backup program of
choice.


## Upgrading paste ownership

Paste owners now use separate `user:<user ID>` and `node:<node ID>` keys from
authenticated WhoIs data. Devices belonging to one user share ownership;
tagged nodes have separate ownership even when they carry the same tags.

Older databases stored both kinds as bare numbers. Equal user and node IDs
could overwrite author metadata and authorize another identity to delete a
paste. Those records cannot reliably identify their original owner: a single
number can refer to pastes created by both kinds of principal.

Upgrading leaves existing paste content, IDs, timestamps, and stored author
records intact. Legacy pastes remain readable, but their delete links are hidden
and deletion requests return HTTP 403. New pastes have normal owner-only
deletion. Stored legacy attribution may already be inaccurate; retaining it
does not recover historical ownership.

### Resolving a verified legacy paste

There is no automatic claiming or bulk numeric-ID migration. An administrator
can resolve an individual paste only after independently verifying its original
owner. Current WhoIs, numeric IDs, names, tags, and stored author metadata alone
do not prove who created a historical paste. Leave unresolved pastes unchanged.

1. Have the verified owner visit the upgraded service so their typed `users.id`
   record exists. Confirm that typed key against the authenticated identity.
2. Stop tclip and make a consistent SQLite backup of `DATA_DIR/data.db`, for
   example with SQLite's `.backup` command.
3. In SQLite, enable foreign keys and update only the verified paste in a
   transaction. Substitute the verified values in this example:

   ```sql
   PRAGMA foreign_keys=ON;
   BEGIN IMMEDIATE;
   UPDATE pastes SET user_id='user:2'
   WHERE id='verified-paste-id' AND user_id='2'
     AND EXISTS (SELECT 1 FROM users WHERE id='user:2');
   SELECT changes();
   ```

   Commit only if `changes()` returns `1` and the selected paste and target owner
   are correct; otherwise roll back. A verified tagged owner uses `node:<node ID>`.
   Keep the legacy `users` row because other unresolved pastes may reference it.
4. Restart tclip. The verified owner can now delete that paste; other legacy
   pastes remain readable and deletion-denied.

Before upgrading, retain a consistent database backup and the tsnet state.
Older binaries cannot fully read typed owner keys and still have the collision
bug; do not run old and new versions against the same database. Downgrading is
not an automatic reversal: preserve post-upgrade data separately before any
restore, since an earlier backup does not contain newer pastes.

## Headscale integration tests

On Linux with KVM and Nix sandboxing enabled:

```sh
nix build .#e2e -L
```

The test is a Linux-only package, rather than a flake check, so ordinary builds
and Darwin evaluation do not require KVM.

`nix/e2e.nix` imports the pinned upstream Headscale `testkit` and `testkit-peer`
modules. Headscale keeps its own nixpkgs input. The server runs the existing
`tclipd` derivation and portable service unit (there is no project NixOS module),
including `DynamicUser` and private state directories. Clients use the existing
`tclip` derivation. Test auth keys are minted inside the VMs, never stored in Nix.

The service uses `TSNET_CONTROL_URL=http://headscale`, `DISABLE_HTTPS=1`, and
`TSNET_DISABLE_NETNS=1`. The last setting lets an unprivileged service reach the
VM LAN even though its default route uses another interface. It grants no extra
capabilities and leaves production interface binding enabled by default.

Coverage:

- Real WhoIs user identity over IPv4 and IPv6, persisted author information,
  shared reads, CLI file
  and stdin uploads, form uploads, raw downloads and attachment headers.
- Owner-only deletion, including another device belonging to the same user;
  cross-user and spoofed-header denial with successful read/delete controls.
- Tagged-node authorship and separate ownership for two nodes carrying one tag.
- A real numeric user/node ID collision: isolated authors, both deletion-denial
  directions, ownership-aware delete links, and both identities across restart.
- Legacy numeric-key pastes stay readable and unchanged alongside new typed
  owners; both colliding principals are denied deletion before and after restart.
  Explicit verified per-paste reassignment preserves content and unrelated rows.
- Direct-path proof and forced `DERP(headscale)` proof alongside application
  uploads/downloads; local-user ACLs (`USER@`), tag ACLs, live deny/reallow, and
  an allowed upload/read while another user is blocked.
- Unprivileged service execution and private state, SQLite and tsnet identity
  across restarts without an auth key, durable deletion, invalid authentication
  and recovery, malformed requests, and direct application traffic during a
  control-server outage followed by relay recovery.
- The optional public HTTP listener: individual paste reads work, private routes
  cannot mutate data, fabricated identity headers cannot grant access, and
  `HIDE_FUNNEL_USERS` hides authors from public HTML.
- Real application HTTPS via `ListenTLS`: a locally trusted certificate in the
  existing tsnet cache, rejection without that trust, direct and DERP uploads,
  ownership and network denials with allowed controls, and TLS after restart.
- Funnel startup fails closed without its node capability, with working HTTPS
  controls before and after the rejected configuration.

The application consumes no custom grants/capabilities. Network authorization
is exercised through Headscale ACLs; application deletion authorization comes
from WhoIs, not capability claims. The only capability-dependent application
feature is Tailscale Funnel, delegated to `tsnet.ListenFunnel`.

These tests do **not** cover cloud Funnel ingress, successful Funnel capability admission,
`ipn.FunnelConn` classification, or public ACME certificate issuance/renewal.
Headscale advertises the application certificate domain; the test seeds tsnet's
existing certificate cache and verifies TLS with an explicit local trust anchor.
The kit's separate self-signed control/DERP certificate is not reused for the app. The public HTTP test covers its shared
read-only mux, not the cloud Funnel transport or its TLS connection context.
HTTP application traffic inside the tailnet still travels over WireGuard.
