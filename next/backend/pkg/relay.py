#!/usr/bin/env python3
"""Configure and run a private Iroh relay using Docker Compose (Python 3.11+)."""

import argparse
import contextlib
import fcntl
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import re
import secrets
import shlex
import shutil
import ssl
import subprocess
import sys
import tempfile
import time

# Match the project's Iroh 1.0 clients; upgrade this deliberately.
DEFAULT_IMAGE = "n0computer/iroh-relay:v1.0.3"
PROJECT = "openvsmobile-relay"


def atomic_write(path, text):
    descriptor, temporary = tempfile.mkstemp(prefix=".relay-", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w") as stream:
            stream.write(text)
        os.replace(temporary, path)
    finally:
        with contextlib.suppress(FileNotFoundError):
            os.unlink(temporary)


def validate_host(value, tls):
    if not isinstance(value, str) or not value:
        raise ValueError("Supply --domain for HTTPS or --host for HTTP")
    try:
        ipaddress.ip_address(value)
    except ValueError:
        pass
    else:
        if tls:
            raise ValueError("HTTPS requires a DNS domain for automatic certificates")
        return value
    if (
        len(value) > 253
        or not all(
            re.fullmatch(r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?", label)
            for label in value.split(".")
        )
        or (tls and "." not in value)
    ):
        raise ValueError(
            "Invalid domain/host; supply a hostname without scheme, port or path"
        )
    return value.lower()


def run(command, **kwargs):
    return subprocess.run(command, check=True, **kwargs)


def compose(directory, *arguments, **kwargs):
    return run(
        [
            "docker",
            "compose",
            "--project-directory",
            str(directory),
            "-p",
            PROJECT + "-" + hashlib.sha256(str(directory).encode()).hexdigest()[:10],
            "-f",
            str(directory / "compose.json"),
            *arguments,
        ],
        **kwargs,
    )


def wait_healthy(directory, settings, timeout):
    # Probe the container locally, even if public DNS has not propagated here.
    # HTTPS still verifies the public certificate against the configured domain.
    host = settings["host"]
    port = settings["https_port"] if settings["tls"] else settings["port"]
    bind = settings["bind"]
    probe_host = "127.0.0.1" if bind == "0.0.0.0" else ("::1" if bind == "::" else bind)
    probe_host = f"[{probe_host}]" if ":" in probe_host else probe_host
    if settings["tls"]:
        if not shutil.which("curl"):
            raise ValueError("HTTPS health checks require curl")
        probe = [
            "curl",
            "--silent",
            "--fail",
            "--noproxy",
            "*",
            "--max-time",
            "3",
            "--resolve",
            f"{host}:{port}:{probe_host}",
            f"https://{host}:{port}/healthz",
        ]
    else:
        probe = [
            sys.executable,
            "-c",
            (
                "import urllib.request; "
                f"o=urllib.request.build_opener(urllib.request.ProxyHandler({{}})); "
                f"o.open('http://{probe_host}:{port}/healthz',timeout=3).read()"
            ),
        ]
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        status = compose(
            directory, "ps", "--all", "--format", "json", capture_output=True, text=True
        )
        # Compose versions emit either a JSON array or one JSON object per line.
        text = status.stdout.strip()
        rows = (
            json.loads(text)
            if text.startswith("[")
            else [json.loads(line) for line in text.splitlines() if line.strip()]
        )
        if rows and all(row.get("State") == "running" for row in rows):
            result = subprocess.run(
                probe, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
            )
            if result.returncode == 0:
                return
        time.sleep(1)
    raise ValueError(
        "Relay did not become healthy before the deadline; it remains available for diagnosis. "
        "Run the logs command and check the certificate, DNS and configured TCP listener."
    )


def configure(directory, args):
    settings_path = directory / "settings.json"
    try:
        saved = json.loads(settings_path.read_text())
    except FileNotFoundError:
        saved = {}
    except (ValueError, OSError):
        raise ValueError(
            "Cannot read settings.json; fix it before continuing"
        ) from None
    if (
        not isinstance(saved, dict)
        or not isinstance(saved.get("tls", True), bool)
        or not isinstance(saved.get("email", ""), str)
    ):
        raise ValueError("Invalid settings.json; fix it before continuing")
    tls = True if args.domain else (False if args.http else saved.get("tls", True))
    if args.domain and args.http:
        raise ValueError("Use --host with --http")
    host = validate_host(args.domain or args.host or saved.get("host"), tls)
    if args.domain and not tls:
        raise ValueError("Use --host with --http")
    if args.host and tls:
        raise ValueError("Use --domain for HTTPS")
    if bool(args.tls_cert) != bool(args.tls_key):
        raise ValueError("Supply --tls-cert and --tls-key together")
    if not tls and any([args.tls_cert, args.tls_key, args.https_port, args.quic_port]):
        raise ValueError(
            "TLS certificate and HTTPS/QAD port options require HTTPS mode"
        )
    cert_path = args.tls_cert or saved.get("tls_cert") if tls else None
    key_path = args.tls_key or saved.get("tls_key") if tls else None
    if bool(cert_path) != bool(key_path):
        raise ValueError("Invalid saved certificate settings")
    manual_tls = bool(cert_path)
    cert_bytes = key_bytes = None
    if manual_tls:
        cert_path = str(Path(cert_path).expanduser().absolute())
        key_path = str(Path(key_path).expanduser().absolute())
        try:
            cert_bytes = Path(cert_path).read_text()
            key_bytes = Path(key_path).read_text()
            context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            context.load_cert_chain(cert_path, key_path, password=lambda: "")
        except (OSError, ValueError, ssl.SSLError):
            raise ValueError(
                "Cannot load TLS certificate/key pair; supply matching PEM files and an unencrypted key"
            ) from None
    email = args.email if args.email is not None else saved.get("email", "")
    if (
        tls
        and not manual_tls
        and not re.fullmatch(
            r"[^\s@\x00-\x1f]+@[^\s@\x00-\x1f]+\.[^\s@\x00-\x1f]+", email
        )
    ):
        raise ValueError("Automatic HTTPS requires --email for the certificate account")
    port = args.port if args.port is not None else saved.get("port", 3340)
    https_port = (
        args.https_port if args.https_port is not None else saved.get("https_port", 443)
    )
    quic_port = (
        args.quic_port if args.quic_port is not None else saved.get("quic_port", 7842)
    )
    for name, value in [
        ("port", port),
        ("https-port", https_port),
        ("quic-port", quic_port),
    ]:
        if not isinstance(value, int) or not 1 <= value <= 65535:
            raise ValueError(f"--{name} must be between 1 and 65535")
    if tls and args.port is not None:
        raise ValueError(
            "--port is for HTTP mode; use --https-port with certificate files"
        )
    if tls and not manual_tls and https_port != 443:
        raise ValueError(
            "Automatic certificates require public port 443; use --tls-cert and --tls-key for other HTTPS ports"
        )
    if tls and not manual_tls and https_port == 80:
        raise ValueError("HTTPS and HTTP ports must differ")
    image = args.image or saved.get("image", DEFAULT_IMAGE)
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._/:@-]+", image):
        raise ValueError("Invalid image reference")
    token_path = directory / "token"
    if token_path.exists():
        token = token_path.read_text().strip()
        if not re.fullmatch(r"[0-9a-f]{64}", token):
            raise ValueError(
                "Invalid token file; expected the generated 64-character hex token"
            )
    else:
        token = secrets.token_hex(32)
    bind = args.bind or saved.get("bind", "0.0.0.0")
    try:
        ipaddress.ip_address(bind)
    except ValueError:
        raise ValueError("--bind must be a local IP address") from None
    settings = {
        "bind": bind,
        "tls": tls,
        "host": host,
        "email": email,
        "port": port,
        "image": image,
        "https_port": https_port,
        "quic_port": quic_port,
        "tls_cert": cert_path,
        "tls_key": key_path,
    }
    config = (
        "enable_relay = true\n"
        f'http_bind_addr = "0.0.0.0:{80 if tls else port}"\n'
        f"enable_quic_addr_discovery = {str(tls).lower()}\n"
        "enable_metrics = false\n"
        f"access.shared_token = [{json.dumps(token)}]\n"
    )
    if tls:
        config += "\n[tls]\n"
        if manual_tls:
            config += (
                'cert_mode = "Reloading"\n'
                'manual_cert_path = "/var/lib/iroh-relay/certs/manual/fullchain.pem"\n'
                'manual_key_path = "/var/lib/iroh-relay/certs/manual/privkey.pem"\n'
            )
        else:
            config += (
                'cert_mode = "LetsEncrypt"\n'
                f"hostname = {json.dumps(host)}\ncontact = {json.dumps(email)}\n"
                'cert_dir = "/var/lib/iroh-relay/certs"\n'
            )
        config += 'https_bind_addr = "0.0.0.0:443"\nquic_bind_addr = "0.0.0.0:7842"\n'
    if tls:
        # Manual certificates need no public HTTP listener or ACME challenge.
        ports = ([] if manual_tls else ["80:80/tcp"]) + [
            f"{https_port}:443/tcp",
            f"{quic_port}:7842/udp",
        ]
    else:
        ports = [f"{port}:{port}/tcp"]
    prefix = f"[{bind}]" if ":" in bind else bind
    ports = [f"{prefix}:{mapping}" for mapping in ports]
    definition = {
        "services": {
            "relay": {
                "image": image,
                "command": ["-c", "/etc/iroh-relay/config.toml"],
                "restart": "unless-stopped",
                "ports": ports,
                "volumes": [
                    {
                        "type": "bind",
                        "source": str(directory / "config.toml"),
                        "target": "/etc/iroh-relay/config.toml",
                        "read_only": True,
                    },
                    {
                        "type": "bind",
                        "source": str(directory / "certs"),
                        "target": "/var/lib/iroh-relay/certs",
                    },
                ],
                "logging": {
                    "driver": "json-file",
                    "options": {"max-size": "10m", "max-file": "3"},
                },
            }
        }
    }
    public_host = f"[{host}]" if ":" in host else host
    url = (
        (f"https://{host}" + (f":{https_port}" if https_port != 443 else ""))
        if tls
        else f"http://{public_host}:{port}"
    )
    env = {
        "OPENVSMOBILE_IROH": "1",
        "OPENVSMOBILE_IROH_RELAY_URLS": url,
        "OPENVSMOBILE_IROH_RELAY_TOKEN": token,
        "OPENVSMOBILE_IROH_RELAY_QUIC_PORT": str(quic_port) if tls else "off",
    }
    (directory / "certs").mkdir(exist_ok=True, mode=0o700)
    if manual_tls:
        manual_dir = directory / "certs" / "manual"
        manual_dir.mkdir(exist_ok=True, mode=0o700)
        atomic_write(manual_dir / "fullchain.pem", cert_bytes)
        atomic_write(manual_dir / "privkey.pem", key_bytes)
    atomic_write(token_path, token + "\n")
    atomic_write(directory / "config.toml", config)
    atomic_write(directory / "compose.json", json.dumps(definition, indent=2) + "\n")
    atomic_write(
        directory / "backend.env",
        "".join(f"export {key}={shlex.quote(value)}\n" for key, value in env.items()),
    )
    atomic_write(
        directory / "openvsmobile-relay.conf",
        "[Service]\n"
        + "".join(f'Environment="{key}={value}"\n' for key, value in env.items()),
    )
    atomic_write(settings_path, json.dumps(settings, indent=2) + "\n")
    return settings, url


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "action", choices=["up", "down", "logs", "status"], nargs="?", default="up"
    )
    parser.add_argument(
        "--dir",
        type=Path,
        default=Path.home() / ".local/share/openvsmobile-relay",
        help="Persistent config, token and certificate directory",
    )
    targets = parser.add_mutually_exclusive_group()
    targets.add_argument("--domain", help="Public DNS name for automatic HTTPS")
    targets.add_argument("--host", help="Client-reachable host or IP for HTTP mode")
    parser.add_argument("--bind", help="Local IP to publish ports on (default 0.0.0.0)")
    parser.add_argument("--email", help="ACME account email for automatic certificates")
    parser.add_argument(
        "--http",
        action="store_true",
        default=None,
        help="Explicit plain HTTP mode for trusted networks (relay token is sent in cleartext)",
    )
    parser.add_argument(
        "--https-port",
        type=int,
        help="Public HTTPS port (default 443); non-443 requires certificate files",
    )
    parser.add_argument(
        "--quic-port", type=int, help="Public UDP QAD port (default 7842)"
    )
    parser.add_argument(
        "--tls-cert", help="Full-chain PEM certificate for --domain (publicly trusted)"
    )
    parser.add_argument("--tls-key", help="Matching unencrypted PEM private key")
    parser.add_argument("--port", type=int, help="HTTP port (default 3340)")
    parser.add_argument(
        "--image", help=f"Override pinned image (default {DEFAULT_IMAGE})"
    )
    parser.add_argument(
        "--configure-only",
        action="store_true",
        help="Write configuration without Docker or starting a relay",
    )
    parser.add_argument(
        "--timeout", type=int, default=120, help="Health check deadline in seconds"
    )
    args = parser.parse_args()
    if args.timeout <= 0:
        parser.error("--timeout must be positive")
    if args.action != "up" and (
        args.configure_only
        or any(
            [
                args.domain,
                args.host,
                args.email,
                args.http,
                args.port,
                args.image,
                args.bind,
                args.https_port,
                args.quic_port,
                args.tls_cert,
                args.tls_key,
            ]
        )
    ):
        parser.error("Configuration options are only valid with up")
    directory = args.dir.expanduser().resolve()
    if args.action != "up" and not (directory / "compose.json").is_file():
        raise ValueError("No configured relay in this directory")
    if not args.configure_only:
        if not shutil.which("docker"):
            raise ValueError(
                "Install Docker Engine and the Docker Compose plugin first"
            )
        run(["docker", "compose", "version"], stdout=subprocess.DEVNULL)
        run(["docker", "info"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if (
        args.action == "up"
        and directory.exists()
        and not (directory / "settings.json").exists()
    ):
        allowed = {
            ".lock",
            "token",
            "config.toml",
            "compose.json",
            "backend.env",
            "openvsmobile-relay.conf",
            "certs",
        }
        if any(path.name not in allowed for path in directory.iterdir()):
            raise ValueError("Choose a dedicated empty directory for relay files")
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(directory, 0o700)
    with (directory / ".lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        if args.action == "up":
            settings, url = configure(directory, args)
            if not args.configure_only:
                if settings["tls"] and not shutil.which("curl"):
                    raise ValueError("Install curl for HTTPS health checks")
                # Validate locally before asking Docker to pull or replace anything.
                compose(directory, "config", "--quiet")
                compose(directory, "up", "-d", "--force-recreate", "--pull", "missing")
                wait_healthy(directory, settings, args.timeout)
            print(f"{'Configured' if args.configure_only else 'Relay healthy'}: {url}")
            print(f"Persistent files: {directory}")
            print(
                f"Backend environment (contains credentials): {directory / 'backend.env'}"
            )
            if settings["tls"]:
                tcp_ports = (
                    str(settings["https_port"])
                    if settings["tls_cert"]
                    else f'80/{settings["https_port"]}'
                )
                print(
                    f'Required public listeners: TCP {tcp_ports}, UDP {settings["quic_port"]}; DNS must point directly to this host.'
                )
        else:
            if args.action == "logs":
                fcntl.flock(lock, fcntl.LOCK_UN)
            compose(
                directory,
                *{
                    "down": ["down"],
                    "logs": ["logs", "--follow", "--tail", "100"],
                    "status": ["ps", "--all"],
                }[args.action],
            )


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        if isinstance(error, subprocess.CalledProcessError):
            message = "Docker command failed; check daemon access, image availability, ports and relay logs"
        elif isinstance(error, BlockingIOError):
            message = "Another relay command is using this directory"
        elif isinstance(error, OSError):
            message = "Cannot access relay files or required commands; check directory permissions"
        else:
            message = str(error)
        print(f"relay: {message}", file=sys.stderr)
        sys.exit(1)
    except KeyboardInterrupt:
        sys.exit(130)
