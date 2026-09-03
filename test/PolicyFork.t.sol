// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {MiniTest} from "./lib/MiniTest.sol";
import {ZeroRewardPolicy} from "../src/ZeroRewardPolicy.sol";
import {
    IAddressConfig,
    IAllocator,
    ILockup,
    IPolicy,
    IPolicyFactory,
    IPolicyGroup,
    IPropertyFactory,
    IProperty
} from "../src/interfaces/IDevProtocol.sol";

/**
 * Mainnet-fork dress rehearsal for the Policy switch: register ZeroRewardPolicy via the
 * REAL PolicyFactory / PolicyGroup / AddressConfig (0x1D415aa…), force-attach it as the
 * owner EOA (0x1dCb85ef…), and assert the mint-rate oracle goes to 0.
 *
 * Precondition observed on mainnet (2026-09-03):
 *   - Allocator.calculateMaxRewardsPerBlock() ≈ 0.1397 DEV/block (non-zero, keeps accruing)
 *   - PolicyFactory.create() is permissionless; forceAttach() is onlyOwner
 *   - the owner EOA of AddressConfig == PolicyFactory owner == 0x1dCb85ef…
 */
contract PolicyForkTest is MiniTest {
    address constant CONFIG = address(uint160(0x001d415aa39d647834786eb9b5a333a50e9935b796));
    address constant LIVE_POLICY = address(uint160(0x001199b3e21ca4b0fb4074adfa770acb58681c8afc));
    address constant CAP_SETTER = address(uint160(0x001c969cd76818769205f52bc25b93e2afe05b386e));
    // Live Policy treasury (owner-set via TreasuryFee.setTreasury): Property creation
    // mints the 5% treasury share of every new Property token to this address.
    address constant TREASURY = address(uint160(0x008f9dc5c9ce6834d8c9897faf5d44ac36ca073595));

    function _fork() internal returns (bool) {
        try vm.createSelectFork("mainnet") returns (uint256) {
            return true;
        } catch {
            return false;
        }
    }

    function test_ForceAttachZeroRewardPolicy_EndToEnd() public {
        if (!_fork()) {
            emit log("SKIP: no RPC");
            return;
        }

        IAddressConfig config = IAddressConfig(CONFIG);
        address owner = config.owner();
        IPolicyFactory factory = IPolicyFactory(config.policyFactory());
        IPolicyGroup group = IPolicyGroup(config.policyGroup());
        IAllocator allocator = IAllocator(config.allocator());

        assertTrue(config.policy() == LIVE_POLICY, "live policy is DIP55 at 0x1199B3E2");

        // Live state before: accrual still running despite the mint-role removal.
        uint256 before = allocator.calculateMaxRewardsPerBlock();
        emit log_named_uint("max rewards/block BEFORE (wei)", before);
        assertTrue(before > 0, "live policy still accrues > 0 per block");

        // Snapshot the values the live Policy exposes, to compare after the switch.
        IPolicy live = IPolicy(LIVE_POLICY);
        uint256 liveMarketVoting = live.marketVotingBlocks();
        uint256 livePolicyVoting = live.policyVotingBlocks();
        uint256 liveHoldersShare = live.holdersShare(100 ether, 1 ether);
        uint256 liveAuthFee = live.authenticationFee(1e24, 0);
        uint256 liveTreasuryShare = live.shareOfTreasury(100 ether);
        // Property.sol mints the treasury share to `policy.treasury()` — must carry over.
        assertEq(live.treasury(), TREASURY, "live treasury snapshot");

        // ── Step 1: deploy + register (permissionless; anyone may call create) ──
        ZeroRewardPolicy zero = new ZeroRewardPolicy(CAP_SETTER, TREASURY);
        vm.prank(address(0xA11CE)); // not the owner: proves permissionlessness
        factory.create(address(zero));

        assertTrue(group.isGroup(address(zero)), "registered in PolicyGroup");
        assertTrue(
            group.isDuringVotingPeriod(address(zero)), "inside the forceAttach window"
        );

        // ── Step 2: force-attach as the owner EOA ──
        vm.prank(owner);
        factory.forceAttach(address(zero));

        assertEq(config.policy(), address(zero), "AddressConfig.policy switched");

        // ── The assertion that matters: mint-rate oracle is pinned to 0 ──
        uint256 after_ = allocator.calculateMaxRewardsPerBlock();
        emit log_named_uint("max rewards/block AFTER (wei)", after_);
        assertEq(after_, 0, "accrual stopped at the source");

        // Direct Policy calls agree.
        assertEq(IPolicy(config.policy()).rewards(10_000_000 ether, 10_000_000 ether), 0, "rewards()==0");

        // Non-emission parameters match the live DIP55 policy byte-for-byte.
        assertEq(
            IPolicy(config.policy()).marketVotingBlocks(),
            liveMarketVoting,
            "marketVotingBlocks unchanged"
        );
        assertEq(
            IPolicy(config.policy()).policyVotingBlocks(),
            livePolicyVoting,
            "policyVotingBlocks unchanged"
        );
        assertEq(
            IPolicy(config.policy()).holdersShare(100 ether, 1 ether),
            liveHoldersShare,
            "holdersShare unchanged (51/49)"
        );
        assertEq(
            IPolicy(config.policy()).authenticationFee(1e24, 0),
            liveAuthFee,
            "authenticationFee unchanged"
        );
        assertEq(
            IPolicy(config.policy()).shareOfTreasury(100 ether),
            liveTreasuryShare,
            "shareOfTreasury unchanged (5%)"
        );
        assertEq(
            IPolicy(config.policy()).capSetter(), CAP_SETTER, "capSetter preserved for updateCap"
        );
        assertEq(
            IPolicy(config.policy()).treasury(),
            TREASURY,
            "treasury preserved for PropertyFactory.create"
        );

        // ── Property creation still works under the new Policy ──
        // Property.sol's constructor mints 5% of the new Property's 10M supply to
        // `policy.treasury()`. With treasury() == 0 it would revert and brick the
        // factory; with the carried-over address it mints exactly like before.
        address newProperty = IPropertyFactory(config.propertyFactory()).create(
            "Zero Reward Smoke Test",
            "ZRST",
            address(0xA11CE)
        );
        assertEq(IProperty(newProperty).author(), address(0xA11CE), "property author");
        assertEq(
            IProperty(newProperty).balanceOf(TREASURY),
            500_000 ether,
            "treasury got the 5% share of the new Property"
        );
        assertEq(
            IProperty(newProperty).balanceOf(address(0xA11CE)),
            9_500_000 ether,
            "author got the 95% share of the new Property"
        );
    }

    /// The negative path: forceAttach must NOT be callable by a non-owner, and must
    /// reject a Policy that was never registered through create().
    function test_ForceAttach_Guards() public {
        if (!_fork()) {
            emit log("SKIP: no RPC");
            return;
        }

        IAddressConfig config = IAddressConfig(CONFIG);
        address owner = config.owner();
        IPolicyFactory factory = IPolicyFactory(config.policyFactory());

        ZeroRewardPolicy zero = new ZeroRewardPolicy(CAP_SETTER, TREASURY);

        // Unregistered → isGroup fails inside forceAttach ("this is illegal address").
        vm.prank(owner);
        vm.expectRevert();
        factory.forceAttach(address(zero));

        // Registered but caller != owner → Ownable reverts before any state change.
        factory.create(address(zero));
        vm.prank(address(0xA11CE));
        vm.expectRevert();
        factory.forceAttach(address(zero));

        // Nothing changed on-chain.
        assertTrue(config.policy() == LIVE_POLICY, "live policy untouched");
    }

    /**
     * Lockup.dry() settlement semantics across the switch:
     *
     * `dry()` (view) accrues `lastAmount` — the per-block rate recorded at the last
     * `update()` — × elapsed blocks, so its result already includes the unsettled
     * interval at the OLD rate. The switch happens mid-interval; the FIRST post-switch
     * `update()` commits exactly the same value the pre-switch view showed, i.e. it
     * settles the pre-switch interval at the old rate EXACTLY ONCE (no double count,
     * no loss). From then on the recorded rate is 0 and every later `update()` and
     * every view accrues nothing — the cumulative value is permanently frozen.
     */
    function test_LockupAccrual_FreezesAfterSwitch() public {
        if (!_fork()) {
            emit log("SKIP: no RPC");
            return;
        }

        IAddressConfig config = IAddressConfig(CONFIG);
        address owner = config.owner();
        IPolicyFactory factory = IPolicyFactory(config.policyFactory());
        IAllocator allocator = IAllocator(config.allocator());
        ILockup lockup = ILockup(config.lockup());

        uint256 rateBefore = allocator.calculateMaxRewardsPerBlock();
        assertTrue(rateBefore > 0, "pre-switch rate > 0");

        // Advance a few blocks so dry() has an interval to settle.
        vm.roll(block.number + 10);

        // Pre-switch VIEW: the unsettled interval is (virtually) accrued at the old rate.
        (uint256 rewardBefore,, uint256 interestBefore,) = lockup.calculateCumulativeRewardPrices();
        emit log_named_uint("cumulative reward BEFORE switch (wei)", rewardBefore);

        // Switch the Policy mid-interval.
        ZeroRewardPolicy zero = new ZeroRewardPolicy(CAP_SETTER, TREASURY);
        factory.create(address(zero));
        vm.prank(owner);
        factory.forceAttach(address(zero));

        // First post-switch update(): settles the interval at the OLD rate, once.
        lockup.update();
        (uint256 rewardSettled,, uint256 interestSettled,) =
            lockup.calculateCumulativeRewardPrices();
        emit log_named_uint("cumulative reward after 1st update (wei)", rewardSettled);
        assertEq(
            rewardSettled,
            rewardBefore,
            "first update settles the pre-switch interval at the old rate, exactly once"
        );

        // Advance several blocks: the view must accrue NOTHING further.
        vm.roll(block.number + 10);
        (uint256 rewardAfterSecond,, uint256 interestAfterSecond,) =
            lockup.calculateCumulativeRewardPrices();
        emit log_named_uint("cumulative reward after +10 blocks (wei)", rewardAfterSecond);
        assertEq(
            rewardAfterSecond,
            rewardSettled,
            "post-settlement views accrue zero (rate pinned to 0)"
        );

        // update() again: still nothing.
        lockup.update();
        vm.roll(block.number + 10);
        lockup.update();
        (uint256 rewardAfterThird,,,, ) = _prices(lockup);
        assertEq(rewardAfterThird, rewardSettled, "accrual permanently frozen");
        assertEq(interestAfterSecond, interestSettled, "interest price frozen too");
        // Sanity: the freeze is BECAUSE of the switch — the pre-switch view already
        // counted the interval at the old rate (settled == pre-switch view), and the
        // post-switch view counts nothing more. Both hold above; nothing else needed.
    }

    function _prices(ILockup lockup)
        internal
        view
        returns (uint256 reward, uint256 holders, uint256 interest, uint256 holdersCap, bool ok)
    {
        (reward, holders, interest, holdersCap) = lockup.calculateCumulativeRewardPrices();
        ok = true; // tuple helper; ok always true
    }
}
