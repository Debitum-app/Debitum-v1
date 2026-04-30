// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {VestingDistributor} from "../../src/VestingDistributor.sol";

/// @notice A malicious ERC20 that re-enters VestingDistributor.distribute inside transferFrom.
contract MaliciousToken is ERC20 {
    VestingDistributor public distributor;
    address            public recipient;
    uint128            public amount;
    bool               public attacking;

    constructor() ERC20("Mal", "MAL") {}

    function setDistributor(address d) external { distributor = VestingDistributor(d); }
    function setTarget(address r, uint128 a) external { recipient = r; amount = a; }
    function mint(address to, uint256 a) external { _mint(to, a); }

    function approve(address spender, uint256 value) public override returns (bool) {
        return super.approve(spender, value);
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        bool result = super.transferFrom(from, to, value);
        // Re-enter distribute on the first call
        if (!attacking && address(distributor) != address(0)) {
            attacking = true;
            address[] memory recips  = new address[](1);
            uint128[]  memory amounts = new uint128[](1);
            recips[0]  = recipient;
            amounts[0] = amount;
            distributor.distribute(address(this), recips, amounts, 0, abi.encode(uint64(30 days)));
        }
        return result;
    }
}

/// @notice Orchestrates a reentrancy attack against VestingDistributor.
contract ReentrancyAttacker {
    MaliciousToken     public token;
    VestingDistributor public distributor;

    constructor(address dist, address /* nft */) {
        distributor = VestingDistributor(dist);
        token = new MaliciousToken();
        token.setDistributor(dist);
    }

    function prepare(address recipient, uint128 amount) external {
        token.setTarget(recipient, amount);
        token.mint(address(this), uint256(amount) * 2);
        token.approve(address(distributor), type(uint256).max);
    }

    function attack() external {
        address[] memory recips  = new address[](1);
        uint128[]  memory amounts = new uint128[](1);
        recips[0]  = token.recipient();
        amounts[0] = token.amount();
        distributor.distribute(address(token), recips, amounts, 0, abi.encode(uint64(30 days)));
    }
}
