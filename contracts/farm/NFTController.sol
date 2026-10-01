// SPDX-License-Identifier: UNLICENSED

pragma solidity 0.6.12;

import "@openzeppelin/contracts/access/Ownable.sol";
import "../interfaces/INFTController.sol";

contract NFTController is INFTController, Ownable {
    mapping(address => bool) public override isWhitelistedNFT;
    mapping(address => uint256) public defaultBoostRate;
    mapping(address => mapping(uint256 => uint256)) public boostRate;

    constructor() public {
    }

    function getBoostRate(address token, uint tokenId) external view override returns (uint) {
        if (!isWhitelistedNFT[token]) {
            return 0;
        }

        uint256 defaultRate = defaultBoostRate[token];
        uint256 rate = boostRate[token][tokenId];

        if (rate > 0) {
            return rate;
        }

        return defaultRate;
    }

    function setWhitelist(address token, bool value) external onlyOwner {
        isWhitelistedNFT[token] = value;
    }

    // value is from 1%
    function setDefaultBoostRate(address token, uint256 value) external onlyOwner {
        defaultBoostRate[token] = value;
    }

    // value is from 1%
    function setBoostRate(address token, uint256 tokenId, uint256 value) external onlyOwner {
        boostRate[token][tokenId] = value;
    }
}
