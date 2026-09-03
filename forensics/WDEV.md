# WDEV Burn Path — Final

## 1. Identifying the WDEV Contract

| Item | Value |
|---|---|
| Address | `0x4a5df63b0c37b38515e4ee51baf40edd420bf7d5` |
| name / symbol | `Polygon Dev Wrapper` / `WDEV` |
| decimals | 18 |
| Current totalSupply | 100,153,849.712469344324277075 WDEV |
| Current DEV holdings (`DEV.balanceOf(WDEV)`) | 100,153,849.712469344324277075 DEV |

`totalSupply == DEV.balanceOf(WDEV)` — **an exact match → a 1:1 fully backed wrapper**.
Detection method: cross-referenced "contracts holding 0.1B DEV" in the full DEV Transfer log analysis → matched the above.

## 2. Wrap / Unwrap Mechanism

- A standard wrapper with `wrap(uint256)` / `unwrap(uint256)` (selector presence confirmed on-chain).
  - `wrap(n)`: pulls `n` DEV from the caller and mints the same amount of WDEV.
  - `unwrap(n)`: burns `n` WDEV and returns the same amount of DEV to the caller (i.e. pays out DEV held inside the WDEV contract).
- Therefore, **the illicit DEV we want to burn physically exists as the WDEV contract's balance**.

## 3. Separating the Illicit Portion from the Legitimate Portion (Confirmed)

WDEV Transfer logs (post-attack):
1. blk 25802137: `0x0` → `0x1932423f` (cluster) minted **100,000,000 WDEV**
   (= the cluster `wrap`ped 100,000,000 illicit DEV, building up backing)
2. blk 25802149: `0x1932423f` → `0x9923263f…` (upgradeable proxy) moved 100,000,000 WDEV

- The **illicit DEV newly backed by the attack = exactly 100,000,000 DEV**.
- WDEV total supply 100,153,849.71 − 100,000,000 = **153,849.712469344 WDEV existed before the attack** —
  the legitimate, third-party backing (still held by pre-attack holders; 0x9923263f also includes a pre-attack portion of 152,974).

## 4. Burn Procedure — Final (`unwrap` is NOT used)

Our only burn capability is `Dev.fee(from, amount)` (burning any holder's DEV as a MarketGroup member).
We have no capability to force-`unwrap` WDEV (that requires the holder's signature). Therefore:

> **Burn the DEV held by the WDEV contract directly via `Dev.fee(WDEV, amount)`**.
> The `amount` is **NOT FULL_BALANCE but the fixed 100,000,000 DEV** (18-decimal wei =
> `100000000000000000000000000`), leaving the third-party legitimate backing of 153,849.71 DEV intact.

After the burn, WDEV becomes "a fractional-reserve state where 153,849.71 DEV backs 100,153,849.71 WDEV".
WDEV's **ERC20 total supply is unchanged** (burning the backing does not reduce WDEV tokens themselves).
The illicit 100M WDEV (held by 0x9923263f) becomes effectively unbacked = worthless (which is the goal).

### Impact Assessment on Other Holders (Important)
- Pre-attack WDEV holders (worth 153,849.71 WDEV) **exist besides the attacker**.
- With the partial burn (fixed 100M), their backing of 153,849.71 DEV is preserved, but because WDEV becomes
  fractional-reserve, a structural risk remains that **whoever `unwrap`s first drains the remaining DEV**
  (the holder of the illicit 100M WDEV could win the race and seize the 153,849). Mitigation requires
  prompting legitimate holders to unwrap in advance (the unwrap path is open to them).
- The alternative **full burn** (`FULL_BALANCE`) reliably destroys the illicit 100M but also wipes out the
  legitimate backing of 153,849.71 as collateral damage.

## 5. Fork Proof Results (WdevBurnFork.t.sol / all PASS)

- `test_WDEV_PartialBurn_SparesLegitBacking`:
  - Pre-burn backing = 100,153,849.712469344 DEV, `==` WDEV.totalSupply (1:1 confirmed)
  - Executed `Dev.fee(WDEV, 100,000,000e18)` → burned amount = exactly 100,000,000 DEV
  - Post-burn `DEV.balanceOf(WDEV)` = **153,849.712469344 DEV** (legitimate backing preserved) confirmed
  - `WDEV.totalSupply()` confirmed unchanged; Settlement's membership confirmed self-revoked within the same TX
- `test_WDEV_FullBurn_DestroysAllBacking`:
  - `FULL_BALANCE` burn → `DEV.balanceOf(WDEV)` = 0 confirmed (proof that all backing is destroyed)

**Conclusion**: the recommendation is the **partial burn (fixed 100,000,000 DEV)**. It preserves the third-party
legitimate backing while reliably destroying only the illicit portion. Switch to the full burn
only if the fractional-reserve race is a concern.
