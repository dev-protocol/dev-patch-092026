// SPDX-License-Identifier: MPL-2.0
pragma solidity ^0.8.20;

import {IPolicy} from "./interfaces/IDevProtocol.sol";

/**
 * @title ZeroRewardPolicy — stops reward accrual at its source
 *
 * $DEV incident remediation, phase 2 (supply-integrity): the protocol's mint authority
 * has already been neutered by removing the protocol addresses from the Dev minter
 * role, so NO new DEV can actually be minted. However `Allocator.calculateMaxRewards
 * PerBlock()` still consults `IPolicy(config().policy()).rewards(...)` every block
 * (currently ≈ 0.1397 DEV/block), and `Lockup` keeps adding that figure into every
 * staker's cumulative reward price — i.e. un-mintable rewards keep accruing as
 * bookkeeping that can never be settled, and would become instantly mintable again
 * if the minter role were ever restored.
 *
 * Attaching this Policy pins `rewards()` to 0, freezing the accrual itself:
 *
 *   - `Allocator.calculateMaxRewardsPerBlock()` returns 0 → cumulative reward prices
 *     stop growing → `Lockup.withdraw` / `Withdraw.withdraw` settle 0 new DEV.
 *   - Defense-in-depth: even a future re-grant of the minter role mints nothing,
 *     because the per-block maximum is 0.
 *   - Everything else is byte-for-byte the live DIP55 behavior, so switching Policies
 *     changes ONLY the emission rate. Specifically `holdersShare` keeps the existing
 *     51/49 split and `authenticationFee` keeps its formula, so the already-accrued
 *     (un-mintable) rewards are divided consistently if they are ever settled.
 *
 * Deployment (2 txs, both from the owner EOA 0x1dCb85ef…):
 *   1. anyone:        `PolicyFactory.create(address(ZeroRewardPolicy))`
 *                     — permissionless; adds it to the PolicyGroup and opens the
 *                       voting window (policyVotingBlocks = 525600 ≈ 74 days).
 *   2. owner:        `PolicyFactory.forceAttach(address(ZeroRewardPolicy))`
 *                     — onlyOwner; validates group membership + voting window,
 *                       then flips AddressConfig.policy().
 *
 * No owner, no config dependency: `rewards()` needs nothing external, and the two
 * addresses that ARE live deployment artifacts (treasury, capSetter) are pinned via
 * constructor args, so this contract cannot break if the registry changes shape
 * after deployment.
 *
 * Deploy with:  new ZeroRewardPolicy(0x1c969CD76818769205F52BC25b93e2aFE05B386E, 0x8F9dc5C9CE6834D8C9897Faf5d44Ac36CA073595)
 *               (capSetter 0x1c969CD7… keeps `Lockup.updateCap` working; treasury
 *                0x8F9dc5C9… keeps `PropertyFactory.create` minting the 5% treasury
 *                share instead of reverting on _mint(address(0), …))
 */
contract ZeroRewardPolicy is IPolicy {
    // ───────────────────────────── emission: the whole point ────────────────────────────

    /// @dev Always 0. Freezes `Allocator.calculateMaxRewardsPerBlock()` and with it
    ///      every staker's cumulative reward price. Args are kept for ABI compat.
    function rewards(uint256, uint256) external pure override returns (uint256) {
        return 0;
    }

    // ─────────────────── everything below mirrors live DIP55 exactly ────────────────────

    /// @dev Live Policy: 51% to Property holders when there are stakers (DIP1+).
    function holdersShare(uint256 _reward, uint256 _lockups)
        external
        pure
        override
        returns (uint256)
    {
        return _lockups > 0 ? (_reward * 51) / 100 : _reward;
    }

    /// @dev Live Policy: totalAssets/10⁴ − propertyLockups/10²³, floored at 0.
    function authenticationFee(uint256 _assets, uint256 _propertyAssets)
        external
        pure
        override
        returns (uint256)
    {
        uint256 a = _assets / 10000;
        uint256 b = _propertyAssets / 100000000000000000000000;
        if (a <= b) {
            return 0;
        }
        return a - b;
    }

    /// @dev Same as live Policy: ~1 year of blocks. Used by PolicyGroup when this
    ///      Policy is registered, and by new Market voting windows.
    function marketVotingBlocks() external pure override returns (uint256) {
        return 525600;
    }

    /// @dev Same as live Policy: ~1 year of blocks. Defines the forceAttach window.
    function policyVotingBlocks() external pure override returns (uint256) {
        return 525600;
    }

    /// @dev Live Policy (TreasuryFee): 5% of the supply delta goes to the treasury.
    function shareOfTreasury(uint256 _supply) external pure override returns (uint256) {
        return (_supply / 100) * 5;
    }

    /// @dev Live Policy (TreasuryFee) returns its owner-set treasury address, and
    ///      the Property constructor MINTS the treasury share of every new Property
    ///      token to it: `_mint(policy.treasury(), toTreasury)`. Returning address(0)
    ///      here would revert `_mint` and brick `PropertyFactory.create` entirely.
    ///      The live address is carried by the constructor parameter instead.
    address public immutable treasury;

    /// @dev Live Policy (DIP55): a dedicated capSetter address (0x1c969Cd7…).
    ///      Returning address(0) here would brick `Lockup.updateCap`; the real
    ///      capSetter is carried by the constructor parameter instead.
    address public immutable capSetter;

    /// @param _capSetter the live capSetter (0x1c969CD76818769205F52BC25b93e2aFE05B386E).
    /// @param _treasury  the live treasury  (0x8F9dc5C9CE6834D8C9897Faf5d44Ac36CA073595),
    ///                  so `PropertyFactory.create` keeps working unchanged.
    constructor(address _capSetter, address _treasury) {
        require(_capSetter != address(0), "capSetter is 0");
        require(_treasury != address(0), "treasury is 0");
        capSetter = _capSetter;
        treasury = _treasury;
    }
}
