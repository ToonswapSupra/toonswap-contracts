// SPDX-License-Identifier: MIT

pragma solidity >=0.5.0;

interface IToonswapFactory {
    event PairCreated(address indexed token0, address indexed token1, address pair, uint);

    function feeTo() external view returns (address);
    function feeToSetter() external view returns (address);

    function getPair(address tokenA, address tokenB) external view returns (address pair);
    function expectPairFor(address token0, address token1) external view returns (address);
    function allPairs(uint) external view returns (address pair);
    function allPairsLength() external view returns (uint);

    function createPair(address tokenA, address tokenB) external returns (address pair);

    function setFeeTo(address) external;
    function setFeeToSetter(address) external;

    function dibs() external view returns (address);
    function treasury() external view returns (address);
    function REFERRAL_FEE() external view returns (uint256);
    function TREASURY_FEE() external view returns (uint256);
    function setDibs(address) external;
    function setTreasury(address) external;
}
