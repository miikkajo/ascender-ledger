# Contributing to Ascender Ledger

Thanks for your interest in contributing to Ascender Ledger. This document covers the
development setup, testing, and pull request guidelines.

## Development setup

Fork and clone the repository:

```bash
git clone https://github.com/<your-user>/ascender-ledger.git
cd ascender-ledger
```

Bring up the three containers locally with Docker Compose:

```bash
./scripts/gen-certs.sh
docker compose up --build
```

`gen-certs.sh` creates the self-signed certificate used by the web and ingest
listeners. Pass `--cert` and `--key` to use an existing certificate instead.

Alternatively, run the same stack under Podman Quadlet:

```bash
sudo ./quadlet/install.sh
```

The installer links the units into `/etc/containers/systemd`, creates the
Podman secrets, generates the certificate, and starts the services. If ports
80 and 443 are already in use, pass `--http-port` and `--https-port`, for
example:

```bash
sudo ./quadlet/install.sh --http-port 8080 --https-port 8443
```

For a rootless install, run the installer as your normal user without `sudo`;
it defaults to ports 8080 and 8443 and manages the stack with
`systemctl --user`.

Source changes under `src/` are bind mounted, so restarting the affected
service picks them up:

```bash
sudo systemctl restart ledger-web.service
```

The web tier is PHP served by nginx, the parser ingests the Ascender log
stream, and the database is MySQL. Container configuration lives in
[`files/`](./files), the Quadlet units live in [`quadlet/`](./quadlet), and
credentials are passed as secrets (Docker or Podman).

## Running tests

There is no automated suite yet. Verify changes by pointing a test Ascender
server at your local Ledger, trusting it under Admins then Servers, and
confirming that facts and changes populate as jobs run.


## Making changes

### Branching

Create a feature branch from `main`:

```bash
git checkout -b my-feature main
```

### Commit messages

Write clear, concise commit messages:

```
Short summary (under 72 characters)

Longer description of what changed and why, if needed.
```

## Submitting a PR

1. Make sure the checks above pass locally.
2. One logical change per PR. Do not bundle unrelated fixes.
3. Target the `main` branch.
4. Explain what changed and why in the PR description.

## Reporting issues

Open an issue at
[github.com/ctrliq/ascender-ledger/issues](https://github.com/ctrliq/ascender-ledger/issues).
Include the version you are running and the steps that reproduce the problem.

For security vulnerabilities, follow [SECURITY.md](./SECURITY.md) instead of
opening a public issue.
