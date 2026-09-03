// SPDX-License-Identifier: MPL-2.0
pragma solidity ^0.8.20;

/// @notice Minimal view of the Dev token (Solidity 0.5.17 on mainnet).
///         ABI-compatible: we only call `fee`, `balanceOf`, `totalSupply`.
interface IDev {
    /// @dev Burns `_amount` from `_from`. Caller MUST be a MarketGroup member.
    ///      There is NO restriction on `_from` — any holder can be burned.
    function fee(address _from, uint256 _amount) external returns (bool);

    function balanceOf(address account) external view returns (uint256);

    function totalSupply() external view returns (uint256);
}

/// @notice AddressConfig — the on-chain service registry. Owner-gated setters.
interface IAddressConfig {
    function token() external view returns (address);

    function marketFactory() external view returns (address);

    function marketGroup() external view returns (address);

    function owner() external view returns (address);

    function policy() external view returns (address);

    function policyFactory() external view returns (address);

    function policyGroup() external view returns (address);

    function propertyFactory() external view returns (address);

    function allocator() external view returns (address);

    function lockup() external view returns (address);

    /// @dev Only the current PolicyFactory may call this (PolicyFactory.create /
    ///      forceAttach path). This is how a new Policy becomes active.
    function setPolicy(address _addr) external;

    /// @dev onlyOwner. Sets the address allowed to call MarketGroup.addGroup/deleteGroup.
    function setMarketFactory(address _addr) external;
}

/// @notice Allocator — reads `IPolicy.rewards()` each block; the mint-rate oracle.
interface IAllocator {
    function calculateMaxRewardsPerBlock() external view returns (uint256);
}

/// @notice Lockup — staking + cumulative reward prices. `dry()`-based `update()`
///         accrues `Allocator.calculateMaxRewardsPerBlock()` × elapsed blocks each
///         call; a 0-rate Policy freezes that accrual after one final settlement.
interface ILockup {
    /// @dev Records the cumulative max-mint and current per-block rate.
    function update() external;

    /// @dev (cumulative reward, holders price, interest price, holders cap).
    function calculateCumulativeRewardPrices()
        external
        view
        returns (uint256, uint256, uint256, uint256);
}

/// @notice PropertyFactory — creates Property tokens. The Property constructor
///         consults the ACTIVE Policy: mints `shareOfTreasury` of its 10M supply to
///         `policy.treasury()` and the rest to the author. A Policy whose treasury()
///         is 0 bricks this factory.
interface IPropertyFactory {
    event Create(address indexed _from, address _property);

    function create(string calldata _name, string calldata _symbol, address _author)
        external
        returns (address);
}

/// @notice Property — an ERC20 whose treasury share is minted at creation.
interface IProperty {
    function author() external view returns (address);

    function balanceOf(address account) external view returns (uint256);
}

/// @notice MarketGroup — the membership set that `Dev.fee` authorizes against.
interface IMarketGroup {
    /// @dev Caller MUST equal config().marketFactory().
    function addGroup(address _addr) external;

    /// @dev Caller MUST equal config().marketFactory().
    function deleteGroup(address _addr) external;

    function isGroup(address _addr) external view returns (bool);

    function getCount() external view returns (uint256);
}

/// @notice Policy — the rewards curve (all Solidity 0.5.17 on mainnet, but the ABI
///         is version-agnostic). `Allocator.calculateMaxRewardsPerBlock()` multiplies
///         this into every staker's cumulative reward price, so `rewards() == 0`
///         stops the accrual of mintable DEV at its source.
interface IPolicy {
    /// @dev Max new DEV per block, given total staked DEV and total authenticated assets.
    function rewards(uint256 _lockups, uint256 _assets) external view returns (uint256);

    function holdersShare(uint256 _amount, uint256 _lockups) external view returns (uint256);

    function authenticationFee(uint256 _assets, uint256 _propertyAssets)
        external
        view
        returns (uint256);

    function marketVotingBlocks() external view returns (uint256);

    function policyVotingBlocks() external view returns (uint256);

    function shareOfTreasury(uint256 _supply) external view returns (uint256);

    function treasury() external view returns (address);

    function capSetter() external view returns (address);
}

/// @notice PolicyFactory — permissionless `create`, owner-gated `forceAttach`.
interface IPolicyFactory {
    event Create(address indexed _from, address _policy);

    function config() external view returns (IAddressConfig);

    function create(address _newPolicyAddress) external;

    /// @dev onlyOwner; policy must be in the group and within its voting window.
    function forceAttach(address _policy) external;
}

/// @notice PolicyGroup — the Policy address set. `isGroup` gates `forceAttach`.
interface IPolicyGroup {
    function addGroup(address _addr) external;

    function isGroup(address _addr) external view returns (bool);

    function isDuringVotingPeriod(address _policy) external view returns (bool);
}

/// @notice Uniswap V2 pair — used to realign reserves after burning pool-held DEV.
interface IUniswapV2Pair {
    function sync() external;

    function skim(address to) external;

    function token0() external view returns (address);

    function token1() external view returns (address);

    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);

    function totalSupply() external view returns (uint256);

    function balanceOf(address account) external view returns (uint256);
}
