// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";

contract FaucetNFT is ERC721 {
    uint256 public tokenId;

    constructor(string memory name, string memory symbol) public ERC721(name, symbol){
    }

    function mint(uint256 amount) external {
        for (uint256 i = 0; i < amount; i++) {
            _mint(msg.sender, tokenId++);
        }
    }
}
