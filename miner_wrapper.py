#!/usr/bin/env python3
"""Teutonic miner wrapper — polls dashboard and runs miner.py when the king changes.

miner.py in unarbos/teutonic is single-shot: it downloads the current king,
perturbs the weights, uploads a challenger repo, and submits a reveal commitment.
That means to stay in contention you need to resubmit whenever:
  - the king hash changes (a new model is crowned), OR
  - your last submission was already evaluated and rejected/accepted, OR
  - enough time has passed that the validator will re-evaluate.

This wrapper drives that loop, respects a minimum gap between submits (to avoid
spamming the chain / HF), and writes a heartbeat for the container HEALTHCHECK.
"""
from __future__ import annotations

import argparse
import json
import logging
import os
import subprocess
import sys
import time
from pathlib import Path

import httpx

HEARTBEAT = Path("/tmp/teutonic-heartbeat")
DASHBOARD_URL = os.environ.get(
    "TEUTONIC_DASHBOARD_URL",
    "https://s3.hippius.com/teutonic-sn3/dashboard.json",
)
LOG_PREFIX = "[teutonic-miner]"

logging.basicConfig(
    level=logging.INFO,
    format=f"%(asctime)s {LOG_PREFIX} %(levelname)s %(message)s",
    datefmt="%Y-%m-%dT%H:%M:%SZ",
)
log = logging.getLogger("wrapper")


def heartbeat() -> None:
    try:
        HEARTBEAT.touch()
    except Exception:
        pass


def fetch_dashboard() -> dict | None:
    try:
        r = httpx.get(DASHBOARD_URL, timeout=15)
        r.raise_for_status()
        return r.json()
    except Exception as e:
        log.warning("dashboard fetch failed: %s", e)
        return None


def get_king_signature(dash: dict) -> tuple[str, str]:
    king = dash.get("king", {}) or {}
    return king.get("king_hash", ""), king.get("king_revision", "")


def get_my_status(dash: dict, my_ss58: str) -> dict:
    """Look for my hotkey in queue / recent submissions."""
    status = {"king": False, "queued": False, "recent_accepted": False, "recent_rejected": False}
    if (dash.get("king", {}) or {}).get("hotkey") == my_ss58:
        status["king"] = True
    for q in dash.get("queue", []) or []:
        if q.get("hotkey") == my_ss58:
            status["queued"] = True
            break
    for r in (dash.get("recent", []) or dash.get("recent_submissions", []) or [])[:50]:
        if r.get("hotkey") == my_ss58:
            verdict = (r.get("verdict") or r.get("result") or "").lower()
            if "accept" in verdict:
                status["recent_accepted"] = True
            elif "reject" in verdict or "fail" in verdict:
                status["recent_rejected"] = True
    return status


def run_miner(args: argparse.Namespace) -> int:
    cmd = [
        sys.executable,
        "/opt/teutonic/miner.py",
        "--hotkey", args.hotkey,
        "--noise", str(args.noise),
    ]
    if args.suffix:
        cmd += ["--suffix", args.suffix]
    if args.force:
        cmd += ["--force"]
    log.info("exec: %s", " ".join(cmd))
    try:
        proc = subprocess.run(cmd, cwd="/opt/teutonic", check=False)
        return proc.returncode
    except Exception as e:
        log.error("miner.py launch failed: %s", e)
        return 99


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--hotkey", required=True)
    p.add_argument("--noise", type=float, default=0.001)
    p.add_argument("--suffix", default=None)
    p.add_argument("--force", action="store_true")
    p.add_argument("--poll-interval", type=int, default=60, help="seconds between dashboard checks")
    p.add_argument("--min-submit-gap", type=int, default=600, help="min seconds between submits")
    args = p.parse_args()

    my_ss58 = os.environ.get("HOTKEY_SS58", "")
    log.info("wrapper up | hotkey=%s ss58=%s noise=%.4f poll=%ds min_gap=%ds force=%s",
             args.hotkey, my_ss58[:10] + "..." if my_ss58 else "?",
             args.noise, args.poll_interval, args.min_submit_gap, args.force)

    last_submit_ts = 0.0
    last_king_sig: tuple[str, str] = ("", "")
    consecutive_failures = 0

    # Initial submit on boot
    run_reasons = ["boot"]

    while True:
        heartbeat()
        now = time.time()
        dash = fetch_dashboard()

        if dash is not None:
            king_sig = get_king_signature(dash)
            status = get_my_status(dash, my_ss58) if my_ss58 else {}
            log.info("dash ok | king=%s@%s stats=%s my_status=%s",
                     king_sig[0][:12], king_sig[1][:8],
                     dash.get("stats", {}), status)

            if status.get("king"):
                log.info("i am king — sleeping, no need to submit against myself")
                last_king_sig = king_sig
                time.sleep(args.poll_interval)
                continue

            if last_king_sig and king_sig and king_sig != last_king_sig:
                run_reasons.append("king_changed")

            # resubmit roughly every min_submit_gap if not queued
            if (now - last_submit_ts) >= args.min_submit_gap and not status.get("queued"):
                run_reasons.append("gap_elapsed")

            last_king_sig = king_sig

        if not run_reasons:
            time.sleep(args.poll_interval)
            continue

        log.info("running miner.py | reasons=%s", ",".join(run_reasons))
        rc = run_miner(args)
        last_submit_ts = time.time()
        heartbeat()
        run_reasons = []

        if rc == 0:
            consecutive_failures = 0
            log.info("miner.py submit OK — entering poll loop")
        else:
            consecutive_failures += 1
            log.warning("miner.py exited rc=%d (consecutive_failures=%d)", rc, consecutive_failures)
            # Backoff on failures so we don't hammer HF / chain
            backoff = min(60 * (2 ** min(consecutive_failures, 6)), 1800)
            log.info("backing off %ds before next attempt", backoff)
            time.sleep(backoff)
            run_reasons.append("retry_after_failure")
            continue

        time.sleep(args.poll_interval)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        log.info("interrupted, exiting")
        sys.exit(0)
