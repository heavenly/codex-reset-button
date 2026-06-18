#!/usr/bin/env python3
"""Small CLI for Codex rate-limit reset credits.

Reads the same ChatGPT token that Codex/Codex CLI stores in ~/.codex/auth.json.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import uuid
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


API_BASE = os.environ.get("CODEX_API_BASE_URL", "https://chatgpt.com/backend-api").rstrip("/")
AUTH_PATH = Path(os.environ.get("CODEX_AUTH_JSON", "~/.codex/auth.json")).expanduser()


def load_auth() -> dict[str, Any]:
    try:
        return json.loads(AUTH_PATH.read_text())
    except FileNotFoundError:
        raise SystemExit(f"auth file not found: {AUTH_PATH}\nRun Codex/Codex CLI login first.")
    except json.JSONDecodeError as e:
        raise SystemExit(f"auth file is not valid JSON: {AUTH_PATH}: {e}")


def access_token() -> str:
    auth = load_auth()
    token = (auth.get("tokens") or {}).get("access_token")
    if not isinstance(token, str) or not token:
        raise SystemExit(f"No ChatGPT access_token found in {AUTH_PATH}")
    return token


def request(method: str, path: str, body: dict[str, Any] | None = None) -> Any:
    data = None if body is None else json.dumps(body).encode("utf-8")
    headers = {
        "Authorization": f"Bearer {access_token()}",
        "originator": "Codex Desktop",
        "User-Agent": "Codex Desktop reset-cli",
        "OAI-Language": "en",
    }
    if body is not None:
        headers["Content-Type"] = "application/json"

    req = urllib.request.Request(API_BASE + path, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            raw = resp.read().decode("utf-8")
            return json.loads(raw) if raw else None
    except urllib.error.HTTPError as e:
        raw = e.read().decode("utf-8", "replace")
        raise SystemExit(f"HTTP {e.code}: {raw or e.reason}")


def parse_time(s: str | None) -> str:
    if not s:
        return "-"
    try:
        dt = datetime.fromisoformat(s.replace("Z", "+00:00"))
        return dt.astimezone(timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")
    except ValueError:
        return s


def cmd_list(args: argparse.Namespace) -> None:
    data = request("GET", "/wham/rate-limit-reset-credits")
    credits = data.get("credits", [])
    available = data.get("available_count", 0)
    print(f"{available} reset{'s' if available != 1 else ''} available")
    for c in credits:
        if args.available and c.get("status") != "available":
            continue
        print(f"\n{c.get('id')}")
        print(f"  status:  {c.get('status')}")
        print(f"  expires: {parse_time(c.get('expires_at'))}")
        title = c.get("title")
        if title:
            print(f"  title:   {title}")


def cmd_redeem(args: argparse.Namespace) -> None:
    if not args.yes:
        raise SystemExit("Refusing to redeem without --yes")
    body: dict[str, Any] = {"redeem_request_id": str(uuid.uuid4())}
    if args.credit_id and args.credit_id != "auto":
        body["credit_id"] = args.credit_id
    result = request("POST", "/wham/rate-limit-reset-credits/consume", body)
    print(json.dumps(result, indent=2))


def main() -> None:
    p = argparse.ArgumentParser(description="Inspect/redeem Codex rate-limit reset credits")
    sub = p.add_subparsers(required=True)

    s = sub.add_parser("list", aliases=["status"], help="show available reset credits and expirations")
    s.add_argument("--available", action="store_true", help="only show available credits")
    s.set_defaults(func=cmd_list)

    r = sub.add_parser("redeem", help="redeem a reset credit")
    r.add_argument("credit_id", nargs="?", default="auto", help="credit id to redeem, or 'auto' (default)")
    r.add_argument("--yes", action="store_true", help="actually redeem the reset")
    r.set_defaults(func=cmd_redeem)

    args = p.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
