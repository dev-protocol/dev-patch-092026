# dev-patch-092026

$DEV incident remediation — atomic burn executor via `Dev.fee()`.

## Prerequisites

- [Foundry](https://getfoundry.sh/) (`forge`, `cast`)
- Python 3 (used by `scripts/compute_burn_deltas.py`, invoked from `path_a_bundle.sh`)
- Ethereum mainnet RPC access (public endpoints work)

## Build & Test

```bash
forge build
forge test -vv
```

Fork tests require RPC access (uses `https://ethereum-rpc.publicnode.com` by default).

## Structure

- `src/Settlement.sol` — Burn executor contract (Path A: deployed factory, Path B: EIP-7702)
- `src/ZeroRewardPolicy.sol` — Phase-2 Policy: pins `rewards()` to 0, stopping reward accrual at its source (deploy via `PolicyFactory.create` + owner `forceAttach`)
- `src/interfaces/IDevProtocol.sol` — Minimal Dev Protocol interfaces
- `test/` — Unit tests + mainnet fork tests
- `forensics/` — Attack cluster analysis and burn target documentation
- `RUNBOOK.md` — operator checklist; execution is `scripts/path_a_bundle.sh`
- `scripts/compute_burn_deltas.py` — pair / FeeCollector snapshot + floor check (`current − pre-attack`); TX2 uses keep-remainder encoding, not these deltas
- `scripts/path_a_bundle.sh` — Path A Flashbots bundle (snapshot → simulate → submit)
</content>
</invoke>
