#!/usr/bin/env python3
"""Compute pair / FeeCollector exploit-derived burn amounts (current − pre-attack).

bash `$((PAIR_NOW - PAIR_PRE))` cannot be used in production:

  1. `cast call … (uint256)` prints `123… [1.23e27]`. `$(( ))` treats `[` as a
     syntax error. On a failed assignment bash may leave a garbage value.
  2. Even with a clean integer, bash arithmetic is signed 64-bit
     (max 9.22e18). Pair / FeeCollector wei are 82–92 bits (~1e24–1e27).

This is the production floor/snapshot calculator for this operation (not a stand-in for
`forge script`). Pair / FeeCollector TX2 amounts are NOT these deltas: the bundle
script encodes `KEEP_OFFSET + pre-attack remainder` so execution burns `live - keep`.
This script fetches live balances via `cast --json` (decimal string, no suffix) and
subtracts with Python integers (unlimited width). stdout is eval-safe `export` lines;
human-readable checks go to stderr. It ABORTs if live < pre-attack (TX2 would revert).

Usage (from repo root, after exporting RPC / address vars if you override defaults):

    eval "$(python3 scripts/compute_burn_deltas.py)"
    echo "$PAIR_DELTA" "$FEE_DELTA"
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys

# Pre-attack DEV balances at block 25801515 (verified on-chain).
# PAIR_PRE  = 3,182,715.966190325101277057 DEV
# FEE_PRE   = 0.220400025594150502 DEV  (wei 220400025594150502 — not 220.40 DEV)
PAIR_PRE = 3_182_715_966_190_325_101_277_057
FEE_PRE = 220_400_025_594_150_502

DEV = os.environ.get("DEV", "0x5caf454ba92e6f2c929df14667ee360ed9fd5b26")
PAIR = os.environ.get("PAIR", "0x4168CEF0fCa0774176632d86bA26553E3B9cF59d")
FEECOLLECTOR = os.environ.get(
    "FEECOLLECTOR", "0x90cbe4bdd538d6e9b379bff5fe72c3d67a521de5"
)
RPC = os.environ.get("RPC", "https://ethereum-rpc.publicnode.com")


def _cast_bin() -> str:
    path = os.environ.get("PATH", "")
    extra = os.path.expanduser("~/.foundry/bin")
    if extra not in path.split(os.pathsep):
        os.environ["PATH"] = path + os.pathsep + extra
    exe = shutil.which("cast")
    if not exe:
        sys.stderr.write("ABORT: `cast` not found (install Foundry)\n")
        sys.exit(1)
    return exe


def balance_of(cast: str, holder: str) -> int:
    raw = subprocess.check_output(
        [
            cast,
            "call",
            DEV,
            "balanceOf(address)(uint256)",
            holder,
            "--rpc-url",
            RPC,
            "--json",
        ],
        text=True,
    )
    decoded = json.loads(raw)
    if isinstance(decoded, list):
        decoded = decoded[0]
    return int(str(decoded), 10)


def fmt_dev(wei: int) -> str:
    whole, frac = divmod(wei, 10**18)
    s = f"{whole:,}.{frac:018d}".rstrip("0").rstrip(".")
    return s


def main() -> int:
    cast = _cast_bin()
    try:
        pair_now = balance_of(cast, PAIR)
        fee_now = balance_of(cast, FEECOLLECTOR)
    except subprocess.CalledProcessError as exc:
        sys.stderr.write(f"ABORT: cast call failed: {exc}\n")
        return 1

    if pair_now < PAIR_PRE:
        sys.stderr.write(
            f"ABORT: pair balance {pair_now} < pre-attack {PAIR_PRE}\n"
        )
        return 1
    if fee_now < FEE_PRE:
        sys.stderr.write(
            f"ABORT: FeeCollector balance {fee_now} < pre-attack {FEE_PRE}\n"
        )
        return 1

    pair_delta = pair_now - PAIR_PRE
    fee_delta = fee_now - FEE_PRE
    if pair_delta <= 0 or fee_delta <= 0:
        sys.stderr.write(
            "ABORT: expected a positive exploit-derived increment on pair and FeeCollector\n"
        )
        return 1

    assert pair_now - pair_delta == PAIR_PRE
    assert fee_now - fee_delta == FEE_PRE

    sys.stderr.write(
        "pair          now={now} DEV\n"
        "              burn delta={delta} DEV\n"
        "              remain after burn={remain} DEV  (must == pre-attack)\n"
        "FeeCollector  now={fnow} DEV\n"
        "              burn delta={fdelta} DEV\n"
        "              remain after burn={fremain} DEV  (must == pre-attack)\n".format(
            now=fmt_dev(pair_now),
            delta=fmt_dev(pair_delta),
            remain=fmt_dev(PAIR_PRE),
            fnow=fmt_dev(fee_now),
            fdelta=fmt_dev(fee_delta),
            fremain=fmt_dev(FEE_PRE),
        )
    )

    # stdout only: eval-safe. No spaces, no comments that break `eval`.
    sys.stdout.write(
        f"export PAIR_NOW={pair_now}\n"
        f"export PAIR_PRE={PAIR_PRE}\n"
        f"export PAIR_DELTA={pair_delta}\n"
        f"export FEE_NOW={fee_now}\n"
        f"export FEE_PRE={FEE_PRE}\n"
        f"export FEE_DELTA={fee_delta}\n"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
