# $DEV Incident Remediation Runbook (Mainnet Operators)

Production burn of ~15.83B exploit-derived DEV via `Dev.fee()`, using `src/Settlement.sol`.

**Execute only through `scripts/path_a_bundle.sh`.** Do not paste ad-hoc `cast send` / `cast mktx` / `eth_sendBundle` fragments. The script never public-broadcasts signed txs (`cast publish` is forbidden).

Publishing targets before `submit` lets holders move DEV out of scope. Disclose forensics only after §3 verify.

---

## 0. Addresses

| Name | Address |
|---|---|
| DEV | `0x5caf454ba92e6f2c929df14667ee360ed9fd5b26` |
| AddressConfig | `0x1D415aa39D647834786EB9B5a333A50e9935b796` |
| marketGroup | `0x54eEFF7ad1e35F7395b1b4f4c86Ec113Eb66F242` |
| marketFactory to restore (ORIGF) | `0xCD82603e66F30162cfc1aE3770510480464F5275` |
| owner EOA | `0x1dCb85efEa6A3FB528d19B9174E88ee35BfF540a` |
| Uniswap V2 pair | `0x4168CEF0fCa0774176632d86bA26553E3B9cF59d` |
| WDEV | `0x4a5df63b0c37b38515e4ee51baf40edd420bf7d5` |
| FeeCollector | `0x90cbe4bdd538d6e9b379bff5fe72c3d67a521de5` |

Burn set (encoded in the script; see `forensics/CLUSTER.md`):

| Target | Amount |
|---|---|
| CL1 `0x58d3382f…` … CL6 `0xef7afd67…` | full live balance |
| CL7 `0x2c00d792…` / CL8 `0x305b38ec…` | full live balance (added 2026-09-03; pre-attack balance 0) |
| WDEV | fixed 100,000,000 DEV |
| FeeCollector | live − `220400025594150502` (0.22040 DEV at block 25801515, **not** 220.40); encoded as keep-remainder |
| Pair | live − `3182715966190325101277057`, then `sync()`; encoded as keep-remainder |

Pair / FeeCollector / WDEV must not be burned to zero.

---

## 1. Checklist (all ✔ before `simulate`)

- [ ] `forge test -vv` PASS on an execution-day fork (`ClusterBurnFork`, `WdevBurnFork`, `PairBurnFork`).
- [ ] Settlement deployed: `config()`, `dev()`, `executor()`, `KEEP_OFFSET()==2^255` match AddressConfig / DEV / the executor EOA / this patch. Executor **≠** owner (this script is 2-key). The script asserts these on `simulate` / `submit`.
- [ ] Owner and executor keys in custody. Both need ETH for gas (owner: TX1+TX3; executor: TX2).
- [ ] Throwaway `AUTH_KEY` for Flashbots relay auth (no funds).
- [ ] `cast chain-id` = 1 on the execution RPC and a backup RPC.
- [ ] Owner can still send a restore `setMarketFactory(ORIGF)` if anything goes wrong after a non-bundle send (should not happen on this path).
- [ ] Disclosure of forensics only after §3 verify.

---

## 2. Execute

The script submits a Flashbots bundle so TX1→TX2→TX3 land in **one block or not at all**:

| TX | Signer | Call |
|---|---|---|
| TX1 | owner | `setMarketFactory(Settlement)` |
| TX2 | executor | `settle` (11 targets + pair `sync`) |
| TX3 | owner | `setMarketFactory(ORIGF)` |

`cast send --flashbots` is **not** this. Protect is per-tx and can still land TX1 alone.

```bash
export PATH="$PATH:$HOME/.foundry/bin"
export RPC=https://ethereum-rpc.publicnode.com   # execution-day RPC
export SETTLEMENT=<deployed Settlement>
export EXECUTOR=<Settlement.executor>            # ≠ owner
export OWNER_KEY=...                             # 0x1dCb85ef…
export EXECUTOR_KEY=...                          # pays TX2
export AUTH_KEY=...                              # relay auth only

cd /path/to/dev-patch-092026

./scripts/path_a_bundle.sh snapshot    # balances + deltas; no signing
./scripts/path_a_bundle.sh simulate    # sign + eth_callBundle; nothing on-chain
./scripts/path_a_bundle.sh submit      # only after simulate OK
./scripts/path_a_bundle.sh verify
```

- Pair / FeeCollector amounts are encoded as `KEEP_OFFSET + pre-attack remainder` inside `scripts/path_a_bundle.sh` (not a live delta). `scripts/compute_burn_deltas.py` is only the snapshot / floor check (live ≥ pre-attack). Do not calculate amounts by hand.
- After `simulate`, check stderr remainders (pair / FeeCollector = pre-attack) and `SIM_OK`. Freeze owner and executor until `submit` lands or you `cancel`.
- If `simulate` fails, do **not** `submit`.
- `submit` re-asserts `chain-id=1`, Settlement identity (`code`, `config()`, `dev()`, `executor()`, `KEEP_OFFSET`), and pair/FeeCollector/WDEV floors each block; aborts and cancels the in-flight bundle if a floor breaks. Optional: `PRIORITY` `MAXFEE` `GAS_SETTLE` (defaults 5gwei / 50gwei / 700000).
- Hardware wallets are not supported by the script (it uses `--private-key`).

Landed = factory is ORIGF, owner nonce advanced by 2, executor nonce advanced by 1, `totalSupply` decreased, TX2 receipt status 1 (`Settled` on TX2).

---

## 3. Verify

`./scripts/path_a_bundle.sh verify` plus:

| Check | Expected |
|---|---|
| Pair DEV + DEV-side reserve | `3182715966190325101277057` |
| FeeCollector | `220400025594150502` |
| CL1–CL8 | 0 |
| WDEV DEV backing | ≈ 153,849.712469344324277075 |
| WDEV `totalSupply` | unchanged vs pre-burn |
| `marketFactory()` | ORIGF |
| `isGroup(Settlement)` | false |
| marketGroup `getCount` | same as pre-`simulate` |

---

## 4. Abort

| Situation | Action |
|---|---|
| `simulate` fails | Stop. Nothing on-chain. Signed txs are inert until `submit`. |
| `submit` not included after ~8 blocks | `./scripts/path_a_bundle.sh cancel`, raise `PRIORITY`/`MAXFEE`, `simulate` again, then `submit`. |
| `submit` aborts on pair/fee/WDEV floor or chain-id | Bundle cancelled if one was in flight. Nothing should be on-chain. Re-check RPC, then `simulate` again. |
| Abort entirely | Do nothing on-chain. Do **not** `cast publish` the signed txs. |
| Bundle in flight | Do **not** also public-send the same txs. |

The script does not send TX1 alone, so a stuck “factory pointed at Settlement” window should not occur. If factory is nevertheless Settlement, owner must `setMarketFactory(ORIGF)` immediately.

Burns via `Dev.fee` cannot be undone. `settle` is all-or-nothing.

---

## 5. Notes (not the happy path)

- **Staged burn:** to shrink the set, change the target list in `scripts/path_a_bundle.sh` (not by pasting calldata). Tier 1 = pair delta + WDEV 100M + FeeCollector delta; then CL3/CL6/CL5; then CL1/CL2/CL4.
- **Path B (EIP-7702):** `forensics/EIP7702.md`. Not in the script. Requires post-tx `--auth 0x0` revocation.
- **CL7 `0x2c00d792` / CL8 `0x305b38ec`**: moved from Grey/EXCLUDE to INCLUDE on 2026-09-03 (MEV/aggregator recipient at blk 25801517 and its exact 10% downstream; both pre-attack balance 0, exploit-derived only). Residual after burn shrinks ≈1.73M → ≈172k DEV.

---

## 6. Phase 2 — Policy switch (stop reward accrual at the source)

**Context.** Mint authority is already dead (protocol addresses removed from the Dev minter role), but `Allocator.calculateMaxRewardsPerBlock()` still computes ≈ 0.1397 DEV/block via the live Policy (DIP55 at `0x1199B3E2…`), and `Lockup` keeps adding that figure into every staker's cumulative reward price. `src/ZeroRewardPolicy.sol` pins `rewards()` to 0; all other IPolicy return values mirror the live DIP55 (51/49 `holdersShare`, `authenticationFee` formula, 525600-block voting windows, 5% `shareOfTreasury`). The two live deployment artifacts are passed to the constructor: **capSetter** `0x1c969CD76818769205F52BC25b93e2aFE05B386E` (keeps `Lockup.updateCap` working) and **treasury** `0x8F9dc5C9CE6834D8C9897Faf5d44Ac36CA073595` (keeps `PropertyFactory.create` working — the Property constructor mints the 5% treasury share to `policy.treasury()`, so a 0 address would brick Property creation).

**Deploy:**

```bash
forge create --rpc-url "$RPC" --private-key <deployer_key> src/ZeroRewardPolicy.sol:ZeroRewardPolicy \
  --constructor-args 0x1c969CD76818769205F52BC25b93e2aFE05B386E 0x8F9dc5C9CE6834D8C9897Faf5d44Ac36CA073595
```

**Execute (2 txs, both simple sends — no bundle needed; independent of the burn in §2):**

| # | Signer | Call |
|---|---|---|
| 1 | anyone | `PolicyFactory(0x9fFAA863…).create(ZeroRewardPolicy)` — permissionless; opens a 525600-block (~74d) forceAttach window |
| 2 | owner | `PolicyFactory(0x9fFAA863…).forceAttach(ZeroRewardPolicy)` — onlyOwner |

**Verify:**

```bash
cast call 0x1D415aa39D647834786EB9B5a333A50e9935b796 "policy()(address)"
cast call 0x2c2807A0Eb5Fd0DFaC8A93A2c9D788154a17B369 "calculateMaxRewardsPerBlock()(uint256)"  # must be 0
```

**Notes:**

- Order vs §2 does not matter (the Policy switch touches no DEV balances).
- `forceAttach` must be sent within the ~74-day window after `create`; if it lapses, `create` a fresh instance (the contract is stateless, so redeployment is free).
- The fork test `test/PolicyFork.t.sol` rehearses the full flow against the live PolicyFactory/PolicyGroup/AddressConfig, asserts max-rewards/block goes 139717807545114121 → 0, and creates a real Property through the live PropertyFactory to prove Property creation survives the switch (treasury share mints to `0x8F9dc5C9…`).
- Already-accrued (un-mintable) rewards remain as bookkeeping; this switch only stops further accrual.
