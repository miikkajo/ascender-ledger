#!/usr/bin/env bash
# Generate or install the TLS certificate used by Ledger's web and ingest
# listeners.  Shared by the Podman Quadlet installer and the Compose workflow.
set -euo pipefail

usage() {
  cat <<EOF
Usage: ${0##*/} [--dir DIR] [--cert FILE --key FILE] [--host NAME]...

  --dir DIR     Directory for ledger.crt and ledger.key (default: ../certs)
  --cert FILE   Install this certificate (PEM) instead of generating one
  --key FILE    Private key for --cert (required with --cert)
  --host NAME   Extra DNS name for a generated certificate; repeatable
EOF
}

script_dir="$(CDPATH= cd -- "$(dirname -- "$(readlink -f -- "$0")")" && pwd)"
cert_dir="$(CDPATH= cd -- "$script_dir/.." && pwd)/certs"
TLS_CERT=""
TLS_KEY=""
TLS_HOSTS=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dir)
      cert_dir="${2:-}"
      shift 2
      ;;
    --cert)
      TLS_CERT="${2:-}"
      shift 2
      ;;
    --key)
      TLS_KEY="${2:-}"
      shift 2
      ;;
    --host)
      if [ -z "${2:-}" ]; then
        echo "--host needs a name." >&2
        exit 2
      fi
      TLS_HOSTS+=("$2")
      shift 2
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

if [ -z "$cert_dir" ]; then
  echo "--dir needs a path." >&2
  exit 2
fi

if [ -n "$TLS_CERT" ] || [ -n "$TLS_KEY" ]; then
  if [ -z "$TLS_CERT" ] || [ -z "$TLS_KEY" ]; then
    echo "--cert and --key must be given together." >&2
    exit 2
  fi
  for file in "$TLS_CERT" "$TLS_KEY"; do
    if [ ! -r "$file" ]; then
      echo "Cannot read TLS file: $file" >&2
      exit 2
    fi
  done
fi

cert_file="$cert_dir/ledger.crt"
key_file="$cert_dir/ledger.key"

if [ -n "$TLS_CERT" ]; then
  mkdir -p "$cert_dir"
  chmod 0755 "$cert_dir"
  install -m 0644 "$TLS_CERT" "$cert_file"
  install -m 0600 "$TLS_KEY" "$key_file"
  echo "Installed TLS certificate from $TLS_CERT."
elif [ -f "$cert_file" ] && [ -f "$key_file" ]; then
  chmod 0644 "$cert_file"
  chmod 0600 "$key_file"
  echo "Using existing TLS certificate $cert_file."
elif [ -f "$cert_file" ] || [ -f "$key_file" ]; then
  echo "Only one of $cert_file and $key_file exists." >&2
  echo "Remove both to generate a new self-signed certificate, or pass --cert/--key." >&2
  exit 1
else
  if ! command -v openssl >/dev/null 2>&1; then
    echo "openssl is required to generate a self-signed certificate." >&2
    exit 1
  fi

  # Cover the names users and Ascender are likely to use, plus every address
  # currently on the host, so the certificate works without knowing the host
  # port in advance.
  san_string=""
  add_san() {
    case ",$san_string," in
      *",$1,"*) return 0 ;;
    esac
    if [ -z "$san_string" ]; then
      san_string="$1"
    else
      san_string="$san_string,$1"
    fi
  }

  primary="$(hostname -f 2>/dev/null || true)"
  if [ -z "$primary" ]; then
    primary="$(hostname 2>/dev/null || true)"
  fi
  if [ -z "$primary" ]; then
    primary="localhost"
  fi

  add_san "DNS:$primary"
  short_name="$(hostname -s 2>/dev/null || true)"
  if [ -n "$short_name" ]; then
    add_san "DNS:$short_name"
  fi
  add_san "DNS:localhost"
  # Ascender runs in a container and reaches Ledger's ingest listener through
  # these aliases; include them so hostname verification can be enabled.
  add_san "DNS:host.containers.internal"
  add_san "DNS:host.docker.internal"
  for name in ${TLS_HOSTS[@]+"${TLS_HOSTS[@]}"}; do
    add_san "DNS:$name"
  done
  add_san "IP:127.0.0.1"
  add_san "IP:::1"
  if command -v hostname >/dev/null 2>&1; then
    for ip in $(hostname -I 2>/dev/null || true); do
      add_san "IP:$ip"
    done
  fi

  mkdir -p "$cert_dir"
  chmod 0755 "$cert_dir"
  echo "Generating a self-signed TLS certificate for $primary..."
  (
    umask 077
    openssl req -x509 -nodes -newkey rsa:2048 -sha256 -days 825 \
      -keyout "$key_file" -out "$cert_file" \
      -subj "/CN=$primary" \
      -addext "subjectAltName=$san_string" \
      -addext "keyUsage=critical,digitalSignature,keyEncipherment" \
      -addext "extendedKeyUsage=serverAuth" \
      -addext "basicConstraints=critical,CA:FALSE"
  )
  chmod 0644 "$cert_file"
  chmod 0600 "$key_file"
  echo "Wrote $cert_file and $key_file."
  echo "Fingerprint: $(openssl x509 -in "$cert_file" -noout -fingerprint -sha256 | cut -d= -f2)"
  echo "This is self-signed: clients must trust it or skip verification."
fi
