// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IAddressConfig, IMarketGroup} from "../../src/interfaces/IDevProtocol.sol";

/// Faithful mock of AddressConfig's gating: setMarketFactory is onlyOwner.
contract MockAddressConfig {
    address public owner;
    address public token;
    address public marketFactory;
    address public marketGroup;

    constructor(address _owner) {
        owner = _owner;
    }

    /// test-only: emulate EIP-7702 by making `owner` the settlement contract's address.
    function setOwner(address a) external {
        owner = a;
    }

    function setToken(address a) external {
        token = a;
    }

    function setMarketGroup(address a) external {
        marketGroup = a;
    }

    function setMarketFactory(address a) external {
        require(msg.sender == owner, "onlyOwner");
        marketFactory = a;
    }
}

/// Faithful mock of MarketGroup: addGroup/deleteGroup require caller == marketFactory.
contract MockMarketGroup {
    IAddressConfig public config;
    mapping(address => bool) internal group;
    uint256 public count;

    constructor(IAddressConfig _config) {
        config = _config;
    }

    function addGroup(address a) external {
        require(msg.sender == config.marketFactory(), "illegal access");
        require(!group[a], "already enabled");
        group[a] = true;
        count++;
    }

    function deleteGroup(address a) external {
        require(msg.sender == config.marketFactory(), "illegal access");
        require(group[a], "not exist");
        group[a] = false;
        count--;
    }

    function isGroup(address a) external view returns (bool) {
        return group[a];
    }

    function getCount() external view returns (uint256) {
        return count;
    }
}

/// Faithful mock of Dev.fee: only a MarketGroup member may burn, and ANY holder is burnable.
contract MockDev {
    IAddressConfig public config;
    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;

    constructor(IAddressConfig _config) {
        config = _config;
    }

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
        totalSupply += amt;
    }

    function fee(address from, uint256 amount) external returns (bool) {
        require(IMarketGroup(config.marketGroup()).isGroup(msg.sender), "this is illegal address");
        if (balanceOf[from] < amount) return false; // insufficient balance → signal failure to caller
        balanceOf[from] -= amount;
        totalSupply -= amount;
        return true;
    }
}

/// Mock Uniswap V2 pair: `reserve` lags `balance` until sync().
contract MockPair {
    MockDev public dev;
    uint112 public reserve;

    constructor(MockDev _dev) {
        dev = _dev;
    }

    function sync() external {
        reserve = uint112(dev.balanceOf(address(this)));
    }
}
