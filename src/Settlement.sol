// SPDX-License-Identifier: MPL-2.0
pragma solidity ^0.8.20;

import {IDev, IAddressConfig, IMarketGroup, IUniswapV2Pair} from "./interfaces/IDevProtocol.sol";

/**
 * @title Settlement — $DEV exploit-derived supply correction — atomic burn executor via Dev.fee()
 *
 * Goal: burn the ~15.83B exploit-derived (illicitly minted) DEV using the ONLY available burn path,
 * `Dev.fee(from, amount)`, which requires `msg.sender` to be a MarketGroup member.
 * Targets are exploit-derived supply requiring correction; per-holder attacker attribution is not required.
 *
 * ── How membership is obtained without deploying/upgrading any protocol contract ──
 * `MarketGroup.addGroup(x)` requires `msg.sender == AddressConfig.marketFactory()`.
 * So if the owner points `marketFactory` at an address we control, that address may
 * register a burner into the group. Two deployment shapes exploit this:
 *
 *   (A) DEPLOYED-FACTORY path  → `settle()`
 *       Owner calls `AddressConfig.setMarketFactory(address(thisContract))`.
 *       Now THIS contract *is* the factory, so it can `addGroup(address(this))`,
 *       making itself a group member, then loop `Dev.fee(...)`. The whole burn
 *       (register-self → burn N targets → sync pairs → deregister-self) is ONE tx.
 *       Registration (setMarketFactory) and restore are 2 separate owner txs.
 *
 *   (B) EIP-7702 OWNER-DELEGATE path → `settleAsOwner()`
 *       The owner EOA (0x1dCb85ef…) sets its code to this implementation for one tx
 *       (EIP-7702, live on mainnet post-Pectra). Running *as the owner account*, a
 *       single call performs setMarketFactory(self) → addGroup(self) → burn → sync →
 *       deregister → setMarketFactory(original). EVERYTHING — registration, burn,
 *       and restore — collapses into ONE atomic transaction.
 *
 * This contract is the production burn executor for mainnet fork-verified remediation.
 */
contract Settlement {
    /// @dev Sentinel for "burn the target's entire current DEV balance".
    uint256 public constant FULL_BALANCE = type(uint256).max;

    /// @dev `amount = KEEP_OFFSET + keepWei` means leave `keepWei` on the holder and
    ///      burn `balanceOf(holder) - keepWei` at execution time. Reverts if the live
    ///      balance is below `keepWei`. Pair / FeeCollector use this so signed calldata
    ///      carries the constant pre-attack remainder, not a simulate-time delta that
    ///      can freeze stale (under-burn on a swap in, over-burn on a swap out).
    ///      `KEEP_OFFSET = 2^255`; `FULL_BALANCE` (2^256-1) is checked first and does
    ///      not collide. Exact burns (e.g. WDEV 100M) are far below `KEEP_OFFSET`.
    uint256 public constant KEEP_OFFSET = 1 << 255;

    struct BurnTarget {
        address holder; // whose DEV to burn
        uint256 amount; // exact, FULL_BALANCE (all), or KEEP_OFFSET + remainder to leave
    }

    IAddressConfig public immutable config;
    IDev public immutable dev;
    address public immutable executor; // who may trigger the deployed-factory path

    event Burned(address indexed holder, uint256 amount);
    event Synced(address indexed pair);
    event Settled(uint256 targets, uint256 totalBurned, uint256 supplyAfter);

    constructor(IAddressConfig _config, address _executor) {
        config = _config;
        dev = IDev(_config.token());
        executor = _executor;
    }

    modifier onlyExecutor() {
        require(msg.sender == executor, "not executor");
        _;
    }

    // ───────────────────────────── Path (A): deployed factory ─────────────────────────────

    /**
     * Preconditions: owner has already run `AddressConfig.setMarketFactory(address(this))`.
     * Effect (single atomic tx): self-register into MarketGroup, burn every target,
     * resync each pool, then self-deregister. Reverts as a whole on any failure.
     * @param targets the holders whose DEV to burn (exact amount, FULL_BALANCE, or KEEP_OFFSET + remainder).
     * @param pairsToSync Uniswap V2 pairs to `sync()` after burning their reserve-backing DEV.
     * @return totalBurned sum of DEV burned across all targets.
     */
    function settle(BurnTarget[] calldata targets, address[] calldata pairsToSync)
        external
        onlyExecutor
        returns (uint256 totalBurned)
    {
        require(config.marketFactory() == address(this), "not the market factory");
        IMarketGroup mg = IMarketGroup(config.marketGroup());

        bool selfRegistered = !mg.isGroup(address(this));
        if (selfRegistered) {
            mg.addGroup(address(this)); // msg.sender == marketFactory == this  ✓
        }

        totalBurned = _burnAll(targets, pairsToSync);

        if (selfRegistered) {
            mg.deleteGroup(address(this)); // leave the group set as we found it
        }

        emit Settled(targets.length, totalBurned, dev.totalSupply());
    }

    // ───────────────────────── Path (B): EIP-7702 owner delegate ──────────────────────────

    /**
     * Intended to run in the owner EOA's context via an EIP-7702 authorization, so that
     * `address(this) == msg.sender == AddressConfig.owner`. Performs the full 5-step
     * remediation — register, burn, sync, deregister, restore — in ONE transaction.
     * Requires the call to be self-sponsored (`msg.sender == address(this)`): during the
     * 7702 delegation window only the delegated EOA itself may invoke this path.
     *
     * @param originalFactory the marketFactory value to restore at the end.
     * @param targets the holders whose DEV to burn (exact amount, FULL_BALANCE, or KEEP_OFFSET + remainder).
     * @param pairsToSync Uniswap V2 pairs to `sync()` after burning their reserve-backing DEV.
     */
    function settleAsOwner(
        address originalFactory,
        BurnTarget[] calldata targets,
        address[] calldata pairsToSync
    ) external returns (uint256 totalBurned) {
        require(originalFactory != address(0) && originalFactory != address(this), "invalid originalFactory");

        // When executed via 7702 delegation, address(this) is the owner account.
        require(address(this) == config.owner(), "must run as owner (7702)");
        require(msg.sender == address(this), "must be self-sponsored (7702)");

        config.setMarketFactory(address(this)); // onlyOwner — satisfied, we are owner
        IMarketGroup mg = IMarketGroup(config.marketGroup());
        mg.addGroup(address(this)); // caller == marketFactory == this  ✓

        totalBurned = _burnAll(targets, pairsToSync);

        mg.deleteGroup(address(this));
        config.setMarketFactory(originalFactory); // restore original wiring

        emit Settled(targets.length, totalBurned, dev.totalSupply());
    }

    // ──────────────────────────────────── shared core ─────────────────────────────────────

    /// @dev Burns all targets via Dev.fee(), then syncs pair reserves to match reduced balances.
    ///      Reverts atomically on any failure (all-or-nothing).
    /// @return totalBurned Sum of DEV burned across all targets.
    function _burnAll(BurnTarget[] calldata targets, address[] calldata pairsToSync)
        internal
        returns (uint256 totalBurned)
    {
        for (uint256 i = 0; i < targets.length; i++) {
            require(targets[i].holder != address(0), "zero address target");
        }
        for (uint256 i = 0; i < targets.length; i++) {
            address holder = targets[i].holder;
            uint256 amount = targets[i].amount;
            if (amount == FULL_BALANCE) {
                amount = dev.balanceOf(holder);
            } else if (amount >= KEEP_OFFSET) {
                uint256 keep = amount - KEEP_OFFSET;
                uint256 bal = dev.balanceOf(holder);
                require(bal >= keep, "below keep target");
                amount = bal - keep;
            }
            if (amount == 0) continue;
            require(dev.fee(holder, amount), "fee failed");
            totalBurned += amount;
            emit Burned(holder, amount);
        }

        // For Uniswap V2 pools we burned reserve-backing DEV directly, so the pair's
        // cached reserves now overstate its DEV. `sync()` rewrites reserves to match the
        // (lower) real balance. NOTE: `skim` is NOT usable here — it only moves the
        // POSITIVE excess (balance − reserve); after a burn balance < reserve, so there
        // is a deficit, not an excess, and skim would transfer nothing (or revert on K).
        for (uint256 j = 0; j < pairsToSync.length; j++) {
            IUniswapV2Pair(pairsToSync[j]).sync();
            emit Synced(pairsToSync[j]);
        }
    }
}
