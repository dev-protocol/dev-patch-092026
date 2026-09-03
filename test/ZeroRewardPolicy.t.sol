// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {MiniTest} from "./lib/MiniTest.sol";
import {ZeroRewardPolicy} from "../src/ZeroRewardPolicy.sol";
import {IPolicy} from "../src/interfaces/IDevProtocol.sol";

/// Unit tests for ZeroRewardPolicy: ABI surface + equivalence with live DIP55 values.
contract ZeroRewardPolicyTest is MiniTest {
    address constant CAP_SETTER = address(0xBEEF);
    address constant TREASURY = address(0xF00D);

    ZeroRewardPolicy policy;

    function setUp() public {
        policy = new ZeroRewardPolicy(CAP_SETTER, TREASURY);
    }

    function test_Constructor_RejectsZeroAddresses() public {
        // address(0) would brick PropertyFactory.create (treasury) / Lockup.updateCap (capSetter).
        vm.expectRevert();
        new ZeroRewardPolicy(address(0), TREASURY);
        vm.expectRevert();
        new ZeroRewardPolicy(CAP_SETTER, address(0));
    }

    // ───────────────────────────── emission: the whole point ────────────────────────────

    function test_Rewards_AlwaysZero() public {
        // Any inputs, including the live mainnet magnitudes.
        assertEq(policy.rewards(0, 0), 0, "rewards(0,0)");
        assertEq(policy.rewards(1 ether, 1), 0, "rewards(1e18,1)");
        assertEq(
            policy.rewards(10_000_000 ether, 10_000_000 ether),
            0,
            "rewards(live magnitudes)"
        );
        assertEq(policy.rewards(type(uint256).max, type(uint256).max), 0, "rewards(max,max)");
    }

    // ─────────────────────── must mirror the live DIP55 Policy ───────────────────────────

    function test_HoldersShare_MatchesDIP1() public {
        // _lockups == 0 → full reward to holders (live behavior).
        assertEq(policy.holdersShare(100 ether, 0), 100 ether, "no stakers: full share");
        // _lockups > 0 → 51%.
        assertEq(policy.holdersShare(100 ether, 1 ether), 51 ether, "stakers: 51%");
        assertEq(policy.holdersShare(0, 1 ether), 0, "zero reward: zero share");
    }

    function test_AuthenticationFee_MatchesLiveFormula() public {
        // Live formula: a = assets/10^4, b = propertyLockups/10^23; a <= b → 0, else a - b.
        // a <= b requires lockups >= assets * 10^19 — heavily-staked Property pays 0.
        assertEq(policy.authenticationFee(1e23, 1e42), 0, "a <= b floors to 0");
        assertEq(policy.authenticationFee(1e23, 1e23), 1e19 - 1, "a - b");
        // assets = 1e24 → a = 1e20; lockups = 0 → b = 0 → fee 1e20.
        assertEq(policy.authenticationFee(1e24, 0), 1e20, "a - b with b = 0");
        assertEq(policy.authenticationFee(0, 0), 0, "0 - 0");
    }

    function test_VotingWindows_MatchLivePolicy() public {
        assertEq(policy.marketVotingBlocks(), 525600, "marketVotingBlocks");
        assertEq(policy.policyVotingBlocks(), 525600, "policyVotingBlocks");
    }

    function test_TreasuryShare_MatchesTreasuryFee() public {
        // TreasuryFee: supply/100*5 — 5% of the supply delta.
        assertEq(policy.shareOfTreasury(100 ether), 5 ether, "5% of supply");
        assertEq(policy.shareOfTreasury(0), 0, "0 of 0");
        // Integer floor like the live contract: 99 wei → 4 (99/100=0, *5=0? no: 99/100=0).
        assertEq(policy.shareOfTreasury(99), 0, "floor at 100 wei units");
        assertEq(policy.shareOfTreasury(199), 5, "199/100=1, *5=5");
    }

    function test_CapSetter_IsTheConstructorArg() public {
        assertEq(policy.capSetter(), CAP_SETTER, "capSetter carried over");
    }

    function test_Treasury_IsTheConstructorArg() public {
        // Property.sol constructor does `_mint(policy.treasury(), toTreasury)` — a
        // wrong treasury bricks PropertyFactory.create; this MUST carry over.
        assertEq(policy.treasury(), TREASURY, "treasury carried over");
    }

    // ──────────────────────────────── ABI compat check ─────────────────────────────────

    /// The live AddressConfig / Lockup / Allocator call IPolicy through this exact
    /// interface — if a selector were missing the whole attach would revert.
    /// Every IPolicy function is exercised through the IPolicy type here.
    function test_SatisfiesIPolicyInterface() public {
        IPolicy asPolicy = IPolicy(address(policy));
        assertTrue(asPolicy.rewards(1, 1) == 0, "rewards via IPolicy");
        assertTrue(asPolicy.holdersShare(1, 1) >= 0, "holdersShare via IPolicy");
        assertTrue(asPolicy.authenticationFee(0, 0) == 0, "authenticationFee via IPolicy");
        assertTrue(asPolicy.marketVotingBlocks() == 525600, "marketVotingBlocks via IPolicy");
        assertTrue(asPolicy.policyVotingBlocks() == 525600, "policyVotingBlocks via IPolicy");
        assertTrue(asPolicy.shareOfTreasury(0) == 0, "shareOfTreasury via IPolicy");
        assertTrue(asPolicy.treasury() == TREASURY, "treasury via IPolicy");
        assertTrue(asPolicy.capSetter() == CAP_SETTER, "capSetter via IPolicy");
    }
}
