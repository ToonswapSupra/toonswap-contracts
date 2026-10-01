// SPDX-License-Identifier: MIT

pragma solidity 0.8.19;

import 'openzeppelin-v4/token/ERC20/ERC20.sol';


contract Token is ERC20 {
    uint8 private _decimals;

    constructor(string memory name, string memory symbol, uint initialSupply, uint8 decimals_) ERC20(name, symbol) {
        _mint(msg.sender, initialSupply);
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(uint amount) external {
        _mint(msg.sender, amount);
    }
}