# Podman Quadlet deployment

These units run the same stack as the `docker-compose.yml` deployment, but under
Podman Quadlet. Quadlet turns the files in this directory into systemd
services, so the stack is managed with `systemctl` instead of `podman compose`.
Compose remains the default standalone deployment; these units are an
alternative for systemd hosts.

| Unit | Purpose |
| ---- | ------- |
| `ledger-web.build`, `ledger-web.container` | Reporting interface over HTTP and HTTPS on ports 80 and 443 by default |
| `ledger-parser.build`, `ledger-parser.container` | Ascender log stream parser on HTTPS port 5000 |
| `ledger-db.build`, `ledger-db.container` | MySQL database, published on `127.0.0.1:3306` |
| `ledger.network` | Private network shared by the three containers |
| `ledger-db-data.volume` | Persistent `/var/lib/mysql` storage |
| `ledger-vendor.volume` | Composer dependencies mounted over the checkout's missing `src/vendor` |

## Install

The containers bind to ports 80 and 443 by default, so install the units as
root:

```bash
sudo ./quadlet/install.sh
```

If another service on the host already uses those ports, such as Ascender
itself, choose different host ports:

```bash
sudo ./quadlet/install.sh --http-port 8080 --https-port 8443
```

To keep plaintext HTTP off the network while still having it available on the
host for diagnostics, publish it on loopback instead:

```bash
sudo ./quadlet/install.sh --http-port 8080 --https-port 8443 \
  --http-bind 127.0.0.1
```

Use `--http-bind ::1` for IPv6 loopback.

The installer:

1. Links this directory to `/etc/containers/systemd/ascender-ledger`.
2. Creates the `admin-password`, `db-ledger-password`, `firstkey`, and
   `secondkey` Podman secrets from the files in `../secrets/`.
3. Generates a self-signed TLS certificate in `../certs/` when none is present,
   or installs the files given with `--tls-cert` and `--tls-key`.
4. Writes a `ledger-web.container.d/10-ports.conf` drop-in when non-default
   ports are requested.
5. Reloads systemd and starts `ledger-web`, `ledger-parser`, and `ledger-db`.

Pass `--no-start` to install without starting the stack.

The units use paths relative to this directory, so keep the repository checkout
in place after installation. The symlink in `/etc/containers/systemd` is
intentional: replacing it with copied unit files would break the image build
context and the `src` bind mounts.

## TLS

The web interface listens for HTTPS as well as HTTP. The HTTPS listener uses
`/etc/nginx/certs/ledger.crt` and `ledger.key`, which the container mounts
read-only from `../certs/`.

`install.sh` generates a self-signed certificate when `certs/ledger.crt` and
`certs/ledger.key` do not exist, using the shared
[`scripts/gen-certs.sh`](../scripts/gen-certs.sh). That script can also be run
directly, which is how the Compose workflow creates the certificate. Its
subject alternative names include the host's FQDN, `localhost`, `127.0.0.1`,
`::1`, `host.containers.internal`, `host.docker.internal`, and every address on
the host. Add more names with `--tls-host`, which may be repeated:

```bash
sudo ./quadlet/install.sh --http-port 8080 --https-port 8443 \
  --tls-host ledger.example.com
```

To use an existing or CA-issued certificate instead, pass both files. They are
copied into `certs/` with the permissions the container expects:

```bash
sudo ./quadlet/install.sh --https-port 8443 \
  --tls-cert /etc/pki/tls/certs/ledger.crt \
  --tls-key  /etc/pki/tls/private/ledger.key
```

The key is stored `0600` and the certificate `0644`; `certs/` is ignored by
git. To replace a certificate later, remove both files (or pass new ones) and
re-run `install.sh`. If the files are already in place, restarting
`ledger-web.service` and `ledger-parser.service` is enough.

A self-signed certificate produces browser warnings until it is trusted.
Import `certs/ledger.crt` into the client trust store, or use `curl -k` for
checks. Note the certificate's fingerprint printed by `install.sh` so the
right one can be verified.

The HTTP listener still serves the application rather than redirecting to
HTTPS. The published HTTPS port is configurable (8443 in the example), so a
redirect would have to guess whether the client reached the host on 443 or
8443. Use the HTTPS URL directly, and set Ledger's `base_url`
(Settings -> General) to it so report and password-reset emails link to the
encrypted endpoint:

```
https://ledger.example.com:8443
```

### Ingest listener (port 5000)

The parser accepts Ascender's log stream over HTTPS on the same certificate and
key mounted from `certs/`. There is no separate certificate to manage. Clients
must trust that certificate; while it is self-signed, Ascender's aggregator has
to skip verification (see below).

Configure Ascender's logging settings:

| Setting | Value |
| ------- | ----- |
| `LOG_AGGREGATOR_TYPE` | `ledger` |
| `LOG_AGGREGATOR_HOST` | `https://host.containers.internal` |
| `LOG_AGGREGATOR_PORT` | `5000` |
| `LOG_AGGREGATOR_PROTOCOL` | `https` |
| `LOG_AGGREGATOR_PASSWORD` | Ledger's auth token |
| `LOG_AGGREGATOR_VERIFY_CERT` | `false` while the certificate is self-signed |

`LOG_AGGREGATOR_PROTOCOL=https` uses HTTPS unless the hostname starts with
`http://`, and `VERIFY_CERT=false` makes rsyslog accept the self-signed
certificate. The generated rsyslog action should contain `usehttps="on"`.
Switch `VERIFY_CERT` back to `true` after replacing the self-signed certificate
with one signed by a CA that Ascender trusts, or after adding the certificate to
Ascender's trust store. The certificate already includes
`host.containers.internal` in its subject alternative names.

### Composer dependencies

The containers bind mount `../src` over `/var/www/html`, so the checkout must
provide the PHP dependencies that `vendor/autoload.php` loads. The image runs
`composer install` at build time, and the `ledger-vendor` volume is seeded from
that image the first time a container starts. This keeps `src/` free of
generated files while preserving the bind mount for editing the rest of the
application.

If `src/composer.json` or `src/composer.lock` changes, rebuild the images and
recreate the volume so it picks up the new dependency set:

```bash
sudo systemctl stop ledger-web.service ledger-parser.service
sudo podman volume rm ledger-vendor
sudo systemctl restart ledger-web.service ledger-parser.service
```

If the volume already contains files, Podman does not overwrite them, which is
why the volume has to be removed rather than just restarted.

## Firewall

Publish the chosen web ports through the host firewall (8080 and 8443 in the
example above, or 80 and 443 for the defaults). To use only the encrypted
endpoint, allow the HTTPS port and omit the HTTP one; the HTTP listener still
binds inside the container, but nothing outside the host can reach it. When
HTTP is published on loopback with `--http-bind 127.0.0.1`, no firewall rule is
needed for it because loopback traffic is already accepted. The containers also
resolve `db` through Podman's DNS server on the bridge gateway, so the host must
accept DNS from the container subnet. The examples below use `10.89.1.0/24`,
the subnet Podman typically assigns to the `ledger` network; check
`podman network inspect ledger` and substitute your own value.

With `firewalld`:

```bash
sudo firewall-cmd --permanent --add-port=8080/tcp --add-port=8443/tcp
sudo firewall-cmd --permanent --add-rich-rule='rule family=ipv4 source address=10.89.1.0/24 port port=53 protocol=udp accept'
sudo firewall-cmd --permanent --add-rich-rule='rule family=ipv4 source address=10.89.1.0/24 port port=53 protocol=tcp accept'
sudo firewall-cmd --reload
```

With a plain nftables ruleset, add the equivalent rules to the input chain
before its drop policy, for example:

```nft
tcp dport { 8080, 8443 } accept
ip saddr 10.89.1.0/24 udp dport 53 accept
ip saddr 10.89.1.0/24 tcp dport 53 accept
```

If Ascender sends job events to `ledger-parser`, it must also be able to reach
port 5000, which serves HTTPS. For a containerized Ascender, point the log
aggregator at `https://host.containers.internal` with port `5000` and the
`https` protocol. With the default self-signed certificate, set
`LOG_AGGREGATOR_VERIFY_CERT` to `false`; see the TLS section above. Do not
publish port 5000 outside the Ascender network: it is an authenticated but
still write-capable endpoint.

## Manage the stack

```bash
systemctl status ledger-web.service ledger-parser.service ledger-db.service
systemctl restart ledger-web.service
journalctl -u ledger-web.service -f
```

The `.build` units run automatically when a container service starts, and
Podman's layer cache makes an unchanged rebuild quick. Restart the container
after changing a Dockerfile or the image contents.

## Migrating from Compose

The old Compose deployment stored MySQL data in Docker's `mysql_data` volume;
these units use a Podman volume named `ledger-db-data`. Moving to Quadlet does
not copy that data automatically. Dump the old database before switching and
restore it after the new stack starts, or copy the old volume's contents into
the new volume before starting the database.

## Secrets

The secret files under `../secrets/` seed the Podman secrets. To change a
credential later, update the file and replace the secret, then restart the
container that uses it:

```bash
sudo podman secret create --replace db-ledger-password secrets/db_ledger_password.txt
sudo systemctl restart ledger-web.service ledger-parser.service ledger-db.service
```

`secrets/admin_password.txt` seeds the initial admin account. Changing it later
also resets the admin password the next time the database container starts.

## Remove

```bash
sudo systemctl stop ledger-web.service ledger-parser.service ledger-db.service
sudo rm /etc/containers/systemd/ascender-ledger
sudo systemctl daemon-reload
```

The `ledger-db-data` volume and the Podman secrets are left in place. Remove
them with `podman volume rm ledger-db-data` and `podman secret rm <name>` only
when the data is no longer needed.
