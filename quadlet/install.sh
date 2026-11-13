#!/usr/bin/env bash
# Install the Ascender Ledger Quadlet units and their Podman secrets.
set -euo pipefail

usage() {
  cat <<EOF
Usage: ${0##*/} [--user] [--http-port PORT] [--https-port PORT]
                 [--ingest-port PORT] [--http-bind ADDRESS]
                 [--tls-cert FILE --tls-key FILE] [--tls-host NAME]... [--no-start]

  --user             Install for the current user under
                     ~/.config/containers/systemd and manage the stack with
                     systemctl --user.  Run as that user, not with sudo.
                     Rootless installs default to ports 8080 and 8443.
  --http-port PORT   Host port for the Ledger web interface
                     (default: 80, or 8080 with --user)
  --https-port PORT  Host port for the Ledger HTTPS interface
                     (default: 443, or 8443 with --user)
  --ingest-port PORT Host port for the parser HTTPS listener (default: 5000)
  --http-bind ADDR   Address to publish the HTTP interface on (default: all).
                     Use 127.0.0.1 to keep plaintext HTTP off the network.
  --tls-cert FILE    Certificate (PEM) for the HTTPS interface.  When omitted, a
                     self-signed certificate is generated in ../certs/.
  --tls-key FILE     Private key for --tls-cert (required with --tls-cert)
  --tls-host NAME    Extra DNS name for the generated certificate; repeatable
  --no-start         Install the units without starting them
EOF
}

USER_MODE=0
HTTP_PORT=""
HTTPS_PORT=""
INGEST_PORT=5000
HTTP_BIND=""
START=1
TLS_CERT=""
TLS_KEY=""
TLS_HOSTS=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    --user)
      USER_MODE=1
      shift
      ;;
    --http-port)
      HTTP_PORT="${2:-}"
      shift 2
      ;;
    --https-port)
      HTTPS_PORT="${2:-}"
      shift 2
      ;;
    --ingest-port)
      INGEST_PORT="${2:-}"
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

# Running as a normal user means a rootless install in that user's Quadlet
# directory.  --user makes that explicit, but root cannot use it: user units
# have to be installed by the user whose manager will run them.
if [ "${EUID}" -ne 0 ]; then
  USER_MODE=1
elif [ "$USER_MODE" -eq 1 ]; then
  echo "Run --user as the target user, not as root." >&2
  echo "For example: sudo -u ledger ./quadlet/install.sh --user" >&2
  exit 1
fi

if [ -z "$HTTP_PORT" ]; then
  if [ "$USER_MODE" -eq 1 ]; then HTTP_PORT=8080; else HTTP_PORT=80; fi
fi
if [ -z "$HTTPS_PORT" ]; then
  if [ "$USER_MODE" -eq 1 ]; then HTTPS_PORT=8443; else HTTPS_PORT=443; fi
fi

for port in "$HTTP_PORT" "$HTTPS_PORT" "$INGEST_PORT"; do
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

if ! command -v podman >/dev/null 2>&1; then
  echo "podman is not installed." >&2
  exit 1
fi

script_dir="$(CDPATH= cd -- "$(dirname -- "$(readlink -f -- "$0")")" && pwd)"
repo_dir="$(CDPATH= cd -- "$script_dir/.." && pwd)"

# Do not depend on the caller's working directory.  In particular, sudo -u can
# leave a root-only directory as the cwd, which makes every podman command fail.
cd "$repo_dir"

if [ "$USER_MODE" -eq 1 ]; then
  user_name="$(id -un)"
  user_home="$(getent passwd "$user_name" | cut -d: -f6)"
  if [ -z "$user_home" ]; then
    user_home="$HOME"
  fi
  config_home="${XDG_CONFIG_HOME:-$user_home/.config}"
  unit_link="$config_home/containers/systemd/ascender-ledger"
  systemctl_cmd=(systemctl --user)

  # Running through sudo or a non-login shell may leave these unset.  A
  # lingering user has a runtime directory and a session bus even without a
  # login session.
  export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
  if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ] && [ -S "$XDG_RUNTIME_DIR/bus" ]; then
    export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
  fi

  # Without lingering, the user manager (and this stack) stops when the last
  # session ends.  A normal user may not be allowed to enable it; print the
  # command to run as an administrator rather than failing the install.
  linger="$(loginctl show-user "$user_name" -p Linger --value 2>/dev/null || true)"
  if [ "$linger" != "yes" ]; then
    if loginctl enable-linger "$user_name" 2>/dev/null; then
      echo "Enabled lingering for $user_name."
    else
      echo "Warning: lingering is not enabled for $user_name." >&2
      echo "The stack will stop when the last session ends. Enable it with:" >&2
      echo "  sudo loginctl enable-linger $user_name" >&2
    fi
  fi

  # The user manager is only available after a login or with lingering.  Give
  # linger a moment to start it before reporting the problem.
  for _ in $(seq 1 20); do
    if "${systemctl_cmd[@]}" show-environment >/dev/null 2>&1; then
      break
    fi
    sleep 0.25
  done
  if ! "${systemctl_cmd[@]}" show-environment >/dev/null 2>&1; then
    echo "Cannot reach the systemd user manager for $user_name." >&2
    echo "Enable lingering and log in once, then re-run this installer:" >&2
    echo "  sudo loginctl enable-linger $user_name" >&2
    exit 1
  fi
else
  unit_link="/etc/containers/systemd/ascender-ledger"
  systemctl_cmd=(systemctl)
fi

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
# umask (for example, root's 077).  A rootless checkout is already owned by the
# user that the container maps to, so it needs no adjustment.
if [ "$USER_MODE" -eq 0 ]; then
  chmod -R a+rX "$repo_dir/src"
fi

# PublishPort cannot be set from the environment, so drop-ins override the
# defaults in the unit files when different host ports are requested.
web_ports_dir="$script_dir/ledger-web.container.d"
web_ports_dropin="$web_ports_dir/10-ports.conf"
if [ "$HTTP_PORT" -eq 80 ] && [ "$HTTPS_PORT" -eq 443 ] && [ -z "$HTTP_BIND" ]; then
  rm -f "$web_ports_dropin"
  rmdir "$web_ports_dir" 2>/dev/null || true
else
  mkdir -p "$web_ports_dir"
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
  cat >"$web_ports_dropin" <<EOF
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

parser_ports_dir="$script_dir/ledger-parser.container.d"
parser_ports_dropin="$parser_ports_dir/10-ports.conf"
if [ "$INGEST_PORT" -eq 5000 ]; then
  rm -f "$parser_ports_dropin"
  rmdir "$parser_ports_dir" 2>/dev/null || true
else
  mkdir -p "$parser_ports_dir"
  cat >"$parser_ports_dropin" <<EOF
[Container]
PublishPort=
PublishPort=$INGEST_PORT:5000
EOF
  echo "Ledger parser will be published on port $INGEST_PORT."
fi

# Secrets keep the same names and default mount paths as the old Compose file:
# /run/secrets/<name>.  In user mode these are created in the user's Podman
# secret store; in system mode they are the root store.
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

"${systemctl_cmd[@]}" daemon-reload

if [ "$START" -eq 0 ]; then
  echo "Quadlet units installed. Start them with:"
  echo "  ${systemctl_cmd[*]} start ledger-web.service ledger-parser.service ledger-db.service"
  exit 0
fi

# Fail with a useful message when another service (for example, Ascender)
# already owns the requested ports.  A rootless process cannot bind ports below
# net.ipv4.ip_unprivileged_port_start even when they are free.
if ! "${systemctl_cmd[@]}" is-active --quiet ledger-web.service && command -v python3 >/dev/null 2>&1; then
  for port in "$HTTP_PORT" "$HTTPS_PORT" "$INGEST_PORT"; do
    result="$(python3 - "$port" <<'PY'
import errno
import socket
import sys

sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
try:
    sock.bind(("0.0.0.0", int(sys.argv[1])))
except PermissionError:
    print("privileged")
except OSError as exc:
    if exc.errno == errno.EADDRINUSE:
        print("in-use")
    else:
        print("unavailable")
else:
    print("free")
finally:
    sock.close()
PY
)"
    case "$result" in
      in-use)
        echo "Port $port is already in use." >&2
        if [ "$USER_MODE" -eq 1 ]; then
          echo "Choose different host ports, for example:" >&2
          echo "  ${0##*/} --http-port 8080 --https-port 8443 --ingest-port 5000" >&2
        else
          echo "Choose different host ports, for example:" >&2
          echo "  sudo ${0##*/} --http-port 8080 --https-port 8443" >&2
        fi
        exit 1
        ;;
      privileged)
        echo "Port $port requires privileges that rootless Podman does not have." >&2
        echo "Choose a port at or above 1024, for example --http-port 8080 --https-port 8443." >&2
        exit 1
        ;;
      unavailable)
        echo "Port $port cannot be bound on this host." >&2
        exit 1
        ;;
    esac
  done
fi

"${systemctl_cmd[@]}" restart ledger-db.service ledger-parser.service ledger-web.service
echo "Started ledger-web, ledger-parser and ledger-db."
if [ "$USER_MODE" -eq 1 ]; then
  echo "Check status with: systemctl --user status ledger-web.service"
else
  echo "Check status with: systemctl status ledger-web.service"
fi
