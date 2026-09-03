// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// Minimal Foundry cheatcode surface — avoids a forge-std dependency (not vendored here).
interface Vm {
    function createSelectFork(string calldata urlOrAlias) external returns (uint256);
    function createSelectFork(string calldata urlOrAlias, uint256 blockNumber) external returns (uint256);
    function prank(address) external;
    function startPrank(address) external;
    function stopPrank() external;
    function deal(address, uint256) external;
    function label(address, string calldata) external;
    function expectRevert() external;
    function expectRevert(bytes calldata) external;
    function load(address, bytes32) external view returns (bytes32);
    function store(address, bytes32, bytes32) external;
    function roll(uint256) external;
    function toString(uint256) external pure returns (string memory);
    function envOr(string calldata, string calldata) external view returns (string memory);
}

/// Tiny Test base with just the assertions we use.
contract MiniTest {
    Vm internal constant vm = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    event log(string);
    event log_named_uint(string key, uint256 val);
    event log_named_address(string key, address val);

    function assertTrue(bool c, string memory err) internal pure {
        require(c, err);
    }

    function assertEq(uint256 a, uint256 b, string memory err) internal pure {
        require(a == b, err);
    }

    function assertEq(address a, address b, string memory err) internal pure {
        require(a == b, err);
    }

    function assertGt(uint256 a, uint256 b, string memory err) internal pure {
        require(a > b, err);
    }
}
