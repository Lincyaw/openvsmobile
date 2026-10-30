#!/usr/bin/env python3
"""Issue an Aliyun DNS-01 certificate and start the private relay on custom ports."""
import argparse
import contextlib
import fcntl
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

ACME_IMAGE = "neilpang/acme.sh:3.1.0"
RELAY_SCRIPT = Path(__file__).with_name("relay.py")


def write_private(path, text):
    fd, temp = tempfile.mkstemp(dir=path.parent, prefix=".dns-")
    try:
        with os.fdopen(fd, "w") as stream:
            stream.write(text)
        os.replace(temp, path)
    finally:
        with contextlib.suppress(FileNotFoundError):
            os.unlink(temp)


def prepare(args, directory):
    settings_file = directory / "dns-settings.json"
    saved = json.loads(settings_file.read_text()) if settings_file.exists() else {}
    if not isinstance(saved, dict):
        raise ValueError("Invalid dns-settings.json")
    domain = args.domain or saved.get("domain")
    email = args.email or saved.get("email")
    if (
        not isinstance(domain, str)
        or not re.fullmatch(r"[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?", domain)
        or "." not in domain
        or ".." in domain
    ):
        raise ValueError("Supply --domain with the relay DNS hostname")
    if not isinstance(email, str) or not re.fullmatch(
        r"[^\s@\x00-\x1f]+@[^\s@\x00-\x1f]+\.[^\s@\x00-\x1f]+", email
    ):
        raise ValueError("Supply --email for the Let's Encrypt account")
    https_port = (
        args.https_port
        if args.https_port is not None
        else saved.get("https_port", 8443)
    )
    quic_port = (
        args.quic_port if args.quic_port is not None else saved.get("quic_port", 9842)
    )
    if any(
        not isinstance(port, int) or not 1 <= port <= 65535
        for port in (https_port, quic_port)
    ):
        raise ValueError("Ports must be between 1 and 65535")
    source = (
        args.credentials.expanduser().resolve()
        if args.credentials
        else directory / "aliyun.env"
    )
    if not source.is_file() or source.stat().st_mode & 0o077:
        raise ValueError(
            "Supply a private --credentials env file (chmod 600) containing Ali_Key and Ali_Secret"
        )
    credentials = {}
    for line in source.read_text().splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        key, separator, value = line.partition("=")
        if (
            not separator
            or key not in ("Ali_Key", "Ali_Secret")
            or not re.fullmatch(r"[A-Za-z0-9_./+=-]+", value)
        ):
            raise ValueError(
                "Credentials file must contain unquoted Ali_Key=value and Ali_Secret=value lines"
            )
        credentials[key] = value
    if set(credentials) != {"Ali_Key", "Ali_Secret"}:
        raise ValueError("Credentials file requires Ali_Key and Ali_Secret")
    for name in ("acme", "issued"):
        (directory / name).mkdir(exist_ok=True, mode=0o700)
    write_private(
        directory / "aliyun.env",
        "".join(f"{key}={value}\n" for key, value in credentials.items()),
    )
    settings = {
        "domain": domain,
        "email": email,
        "https_port": https_port,
        "quic_port": quic_port,
    }
    write_private(settings_file, json.dumps(settings, indent=2) + "\n")
    return settings


def acme_command(directory, arguments):
    # The official image runs as root. Return mounted files to the invoking user
    # even on failure, so normal Docker-group users can read their certificates.
    shell = 'trap \'result=$?; chown -R "$OVSM_UID:$OVSM_GID" /acme.sh /issued; chmod -R go-rwx /acme.sh /issued; exit "$result"\' EXIT\n/root/.acme.sh/acme.sh --config-home /acme.sh "$@"'
    return [
        "docker",
        "run",
        "--rm",
        "--env-file",
        str(directory / "aliyun.env"),
        "-e",
        "AUTO_UPGRADE=0",
        "-e",
        f"OVSM_UID={os.getuid()}",
        "-e",
        f"OVSM_GID={os.getgid()}",
        "--mount",
        f"type=bind,src={directory / 'acme'},dst=/acme.sh",
        "--mount",
        f"type=bind,src={directory / 'issued'},dst=/issued",
        "--entrypoint",
        "/bin/sh",
        ACME_IMAGE,
        "-c",
        shell,
        "acme",
        *arguments,
    ]


def execute_acme(directory, arguments, allow_skip=False):
    # Keep upstream diagnostics in a private log; API credentials never reach
    # terminal output, even if an upstream error unexpectedly echoes a request.
    with (directory / "acme.log").open("ab") as log:
        os.chmod(directory / "acme.log", 0o600)
        result = subprocess.run(
            acme_command(directory, arguments), stdout=log, stderr=log
        )
    if result.returncode not in ((0, 2) if allow_skip else (0,)):
        raise ValueError(
            f"Certificate operation failed; inspect the private log at {directory / 'acme.log'}"
        )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "action",
        choices=["up", "renew", "down", "logs", "status"],
        nargs="?",
        default="up",
    )
    parser.add_argument(
        "--dir",
        type=Path,
        default=Path.home() / ".local/share/openvsmobile-relay-aliyun",
    )
    parser.add_argument("--domain")
    parser.add_argument("--email")
    parser.add_argument(
        "--credentials",
        type=Path,
        help="Private Docker env file containing Ali_Key and Ali_Secret",
    )
    parser.add_argument("--https-port", type=int, help="Default 8443")
    parser.add_argument("--quic-port", type=int, help="Default 9842")
    parser.add_argument(
        "--configure-only",
        action="store_true",
        help="Save the DNS certificate plan without contacting DNS/ACME or starting services",
    )
    args = parser.parse_args()
    directory = args.dir.expanduser().resolve()
    if args.action in ("down", "logs", "status"):
        if any(
            [
                args.domain,
                args.email,
                args.credentials,
                args.https_port,
                args.quic_port,
                args.configure_only,
            ]
        ):
            parser.error("Setup options require up or renew")
        return subprocess.call(
            [
                sys.executable,
                str(RELAY_SCRIPT),
                args.action,
                "--dir",
                str(directory / "relay"),
            ]
        )
    if not directory.exists():
        directory.mkdir(parents=True, mode=0o700)
    elif not (directory / "dns-settings.json").exists() and any(
        p.name not in {".lock"} for p in directory.iterdir()
    ):
        raise ValueError("Choose a dedicated empty directory for DNS certificate state")
    os.chmod(directory, 0o700)
    with (directory / ".lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        settings = prepare(args, directory)
        relay_args = [
            sys.executable,
            str(RELAY_SCRIPT),
            "--dir",
            str(directory / "relay"),
            "--domain",
            settings["domain"],
            "--https-port",
            str(settings["https_port"]),
            "--quic-port",
            str(settings["quic_port"]),
            "--tls-cert",
            str(directory / "issued/fullchain.pem"),
            "--tls-key",
            str(directory / "issued/privkey.pem"),
        ]
        if args.configure_only:
            write_private(
                directory / "plan.json",
                json.dumps(
                    {
                        "acmeImage": ACME_IMAGE,
                        "dnsProvider": "dns_ali",
                        "relayCommand": relay_args,
                    },
                    indent=2,
                )
                + "\n",
            )
            print(
                f"DNS-01 plan saved: {directory / 'plan.json'}; no DNS changes or service startup performed"
            )
            return 0
        if not shutil.which("docker"):
            raise ValueError("Install Docker Engine and Compose first")
        print(
            "Issuing/checking the certificate through Aliyun DNS-01; ports 80/443 are not used.",
            flush=True,
        )
        fullchain = directory / "issued/fullchain.pem"
        before = fullchain.read_bytes() if fullchain.exists() else None
        execute_acme(
            directory,
            ["--register-account", "--server", "letsencrypt", "-m", settings["email"]],
        )
        execute_acme(
            directory,
            [
                "--issue",
                "--server",
                "letsencrypt",
                "--dns",
                "dns_ali",
                "-d",
                settings["domain"],
                "--keylength",
                "ec-256",
            ],
            allow_skip=True,
        )
        execute_acme(
            directory,
            [
                "--install-cert",
                "-d",
                settings["domain"],
                "--ecc",
                "--fullchain-file",
                "/issued/fullchain.pem",
                "--key-file",
                "/issued/privkey.pem",
            ],
        )
        if args.action == "renew" and before == fullchain.read_bytes():
            print("Certificate is unchanged; relay keeps running.")
            return 0
        return subprocess.call(relay_args)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (ValueError, OSError) as error:
        message = (
            str(error)
            if isinstance(error, ValueError)
            else "Cannot access DNS state or Docker; check permissions"
        )
        print(f"relay-aliyun: {message}", file=sys.stderr)
        sys.exit(1)
    except KeyboardInterrupt:
        sys.exit(130)
