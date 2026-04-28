// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockERC20 is ERC20 {
    uint8 private _dec;

    constructor(string memory name, string memory symbol, uint8 dec) ERC20(name, symbol) {
        _dec = dec;
    }

    function decimals() public view override returns (uint8) { return _dec; }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Simulates USDT-style tokens that revert when approving from a non-zero allowance.
contract MockUSDT is ERC20 {
    constructor() ERC20("Mock USDT", "MUSDT") {}

    function decimals() public pure override returns (uint8) { return 6; }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function approve(address spender, uint256 amount) public override returns (bool) {
        require(
            amount == 0 || allowance(msg.sender, spender) == 0,
            "USDT: approve from non-zero"
        );
        return super.approve(spender, amount);
    }
}
