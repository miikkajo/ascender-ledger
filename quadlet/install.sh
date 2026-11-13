#!/usr/bin/env bash
# Install the Ascender Ledger Quadlet units and their Podman secrets.
set -euo pipefail

usage() {
  cat <<EOF
Usage: ${0##*/} [--http-port PORT] [--https-port PORT]
                 [--http-bind ADDRESS]
                 [--tls-cert FILE --tls-key FILE] [--tls-host NAME]... [--no-start]

  --http-port PORT   Host port for the Ledger web interface (default: 80)
  --https-port PORT  Host port for the Ledger HTTPS interface (default: 443)
  --http-bind ADDR   Address to publish the HTTP interface on (default: all).
                     Use 127.0.0.1 to keep plaintext HTTP off the network.
  --tls-cert FILE    Certificate (PEM) for the HTTPS interface.  When omitted, a
                     self-signed certificate is generated in ../certs/.
  --tls-key FILE     Private key for --tls-cert (required with --tls-cert)
  --tls-host NAME    Extra DNS name for the generated certificate; repeatable
  --no-start         Install the units without starting them
EOF
}

HTTP_PORT=80
HTTPS_PORT=443
HTTP_BIND=""
START=1
TLS_CERT=""
TLS_KEY=""
TLS_HOSTS=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    --http-port)
      HTTP_PORT="${2:-}"
      shift 2
      ;;
    --https-port)
      HTTPS_PORT="${2:-}"
      shift 2
      ;;
    --http-bind)
      HTTP_BIND="${2:-}"
      shift 2
      ;;
    --tls-cert)
      TLS_CERT="${2:-}"
      shift 2
      ;;
    --tls-key)
      TLS_KEY="${2:-}"
      shift 2
      ;;
    --tls-host)
      if [ -z "${2:-}" ]; then
        echo "--tls-host needs a name." >&2
        exit 2
      fi
      TLS_HOSTS+=("$2")
      shift 2
      ;;
    --no-start)
      START=0
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
done

for port in "$HTTP_PORT" "$HTTPS_PORT"; do
  case "$port" in
    ''|*[!0-9]*)
      echo "Invalid port: $port" >&2
      exit 2
      ;;
  esac
  if [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
    echo "Invalid port: $port" >&2
    exit 2
  fi
done

if [ -n "$HTTP_BIND" ]; then
  case "$HTTP_BIND" in
    *[[:space:]]*)
      echo "Invalid --http-bind address: $HTTP_BIND" >&2
      exit 2
      ;;
  esac
fi

if [ -n "$TLS_CERT" ] || [ -n "$TLS_KEY" ]; then
  if [ -z "$TLS_CERT" ] || [ -z "$TLS_KEY" ]; then
    echo "--tls-cert and --tls-key must be given together." >&2
    exit 2
  fi
  for file in "$TLS_CERT" "$TLS_KEY"; do
    if [ ! -r "$file" ]; then
      echo "Cannot read TLS file: $file" >&2
      exit 2
    fi
  done
fi

if [ "${EUID}" -ne 0 ]; then
  echo "Run this installer as root (for example, with sudo)." >&2
  exit 1
fi

if ! command -v podman >/dev/null 2>&1; then
  echo "podman is not installed." >&2
  exit 1
fi

script_dir="$(CDPATH= cd -- "$(dirname -- "$(readlink -f -- "$0")")" && pwd)"
repo_dir="$(CDPATH= cd -- "$script_dir/.." && pwd)"
unit_link="/etc/containers/systemd/ascender-ledger"

# TLS for the web interface and the ingest listener.  The shared script keeps
# certificate handling identical for the Compose and Quadlet deployments; the
# containers mount ../certs read-only.
cert_args=(--dir "$repo_dir/certs")
if [ -n "$TLS_CERT" ]; then
  cert_args+=(--cert "$TLS_CERT" --key "$TLS_KEY")
fi
for name in ${TLS_HOSTS[@]+"${TLS_HOSTS[@]}"}; do
  cert_args+=(--host "$name")
done
"$repo_dir/scripts/gen-certs.sh" "${cert_args[@]}"

# The source mount and image build context are resolved relative to the units,
# so link the whole directory instead of copying individual files.
if [ -L "$unit_link" ]; then
  rm -f "$unit_link"
elif [ -e "$unit_link" ]; then
  echo "$unit_link exists and is not a symlink; refusing to replace it." >&2
  exit 1
fi
mkdir -p "$(dirname "$unit_link")"
ln -s "$script_dir" "$unit_link"
echo "Installed Quadlet units at $unit_link"

# nginx and php-fpm run as the unprivileged nginx user in the web and parser
# containers. The src directory is bind mounted from the checkout, so make it
# traversable/readable even when the repository was cloned with a restrictive
# umask (for example, root's 077).
chmod -R a+rX "$repo_dir/src"

# PublishPort cannot be set from the environment, so a drop-in overrides the
# two ports when they differ from the defaults in ledger-web.container.
ports_dir="$script_dir/ledger-web.container.d"
ports_dropin="$ports_dir/10-ports.conf"
if [ "$HTTP_PORT" -eq 80 ] && [ "$HTTPS_PORT" -eq 443 ] && [ -z "$HTTP_BIND" ]; then
  rm -f "$ports_dropin"
  rmdir "$ports_dir" 2>/dev/null || true
else
  mkdir -p "$ports_dir"
  # PublishPort takes [[ip]:hostPort]:containerPort, with IPv6 addresses in
  # brackets.  An empty --http-bind publishes on every address.
  http_publish="$HTTP_PORT:80"
  if [ -n "$HTTP_BIND" ]; then
    case "$HTTP_BIND" in
      \[*\]) http_publish="$HTTP_BIND:$HTTP_PORT:80" ;;
      *:*)   http_publish="[$HTTP_BIND]:$HTTP_PORT:80" ;;
      *)     http_publish="$HTTP_BIND:$HTTP_PORT:80" ;;
    esac
  fi
  cat >"$ports_dropin" <<EOF
[Container]
PublishPort=
PublishPort=$http_publish
PublishPort=$HTTPS_PORT:443
EOF
  if [ -n "$HTTP_BIND" ]; then
    echo "Ledger web will be published on $HTTP_BIND:$HTTP_PORT (HTTP) and port $HTTPS_PORT (HTTPS)."
  else
    echo "Ledger web will be published on ports $HTTP_PORT (HTTP) and $HTTPS_PORT (HTTPS)."
  fi
fi

# Secrets keep the same names and default mount paths as the old Compose file:
# /run/secrets/<name>.
create_secret() {
  local name="$1" file="$2"
  if [ ! -f "$file" ]; then
    echo "Missing secret file: $file" >&2
    return 1
  fi
  podman secret create --replace "$name" "$file" >/dev/null
  echo "Created Podman secret: $name"
}

create_secret admin-password "$repo_dir/secrets/admin_password.txt"
create_secret db-ledger-password "$repo_dir/secrets/db_ledger_password.txt"
create_secret firstkey "$repo_dir/secrets/firstkey.txt"
create_secret secondkey "$repo_dir/secrets/secondkey.txt"

systemctl daemon-reload

if [ "$START" -eq 0 ]; then
  echo "Quadlet units installed. Start them with:"
  echo "  systemctl start ledger-web.service ledger-parser.service ledger-db.service"
  exit 0
fi

# Fail with a useful message when another service (for example, Ascender)
# already owns the requested ports.
if ! systemctl is-active --quiet ledger-web.service && command -v python3 >/dev/null 2>&1; then
  for port in "$HTTP_PORT" "$HTTPS_PORT"; do
    if python3 - "$port" <<'PY'
import socket
import sys

sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
try:
    sock.bind(("0.0.0.0", int(sys.argv[1])))
except OSError:
    sys.exit(0)  # in use
else:
    sys.exit(1)  # free
finally:
    sock.close()
PY
    then
      echo "Port $port is already in use." >&2
      echo "Choose different host ports, for example:" >&2
      echo "  sudo ${0##*/} --http-port 8080 --https-port 8443" >&2
      exit 1
    fi
  done
fi

systemctl restart ledger-db.service ledger-parser.service ledger-web.service
echo "Started ledger-web, ledger-parser and ledger-db."
echo "Check status with: systemctl status ledger-web.service"
