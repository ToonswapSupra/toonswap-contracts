// SPDX-License-Identifier: MIT

pragma solidity >=0.5.16;

import '../libraries/ToonswapLibrary.sol';
import './Pair.sol';

contract ToonswapFactory {
    bytes32 public constant INIT_CODE_PAIR_HASH = keccak256(abi.encodePacked(type(ToonswapPair).creationCode));

    address public feeTo;
    address public feeToSetter;
    address public dibs;                // referral fee handler
    address public treasury;           // treasury address

    uint256 public REFERRAL_FEE = 1600; // 0.04%
    uint256 public TREASURY_FEE = 3600; // 0.09%

    mapping(address => mapping(address => address)) public getPair;
    address[] public allPairs;

    event PairCreated(address indexed token0, address indexed token1, address pair, uint);

    constructor(address _feeToSetter) public {
        feeToSetter = _feeToSetter;
    }

    function allPairsLength() external view returns (uint) {
        return allPairs.length;
    }

    function expectPairFor(address token0, address token1) public view returns (address) {
        return ToonswapLibrary.pairFor(address(this), token0, token1);
    }

    function createPair(address tokenA, address tokenB) external returns (address pair) {
        require(tokenA != tokenB, 'Toonswap: IDENTICAL_ADDRESSES');
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        require(token0 != address(0), 'Toonswap: ZERO_ADDRESS');
        require(getPair[token0][token1] == address(0), 'Toonswap: PAIR_EXISTS'); // single check is sufficient
        bytes memory bytecode = type(ToonswapPair).creationCode;
        bytes32 salt = keccak256(abi.encodePacked(token0, token1));
        assembly {
            pair := create2(0, add(bytecode, 32), mload(bytecode), salt)
        }
        IToonswapPair(pair).initialize(token0, token1);
        getPair[token0][token1] = pair;
        getPair[token1][token0] = pair; // populate mapping in the reverse direction
        allPairs.push(pair);
        emit PairCreated(token0, token1, pair, allPairs.length);
    }

    function setFeeTo(address _feeTo) external {
        require(msg.sender == feeToSetter, 'Toonswap: FORBIDDEN');
        feeTo = _feeTo;
    }

    function setFeeToSetter(address _feeToSetter) external {
        require(msg.sender == feeToSetter, 'Toonswap: FORBIDDEN');
        feeToSetter = _feeToSetter;
    }

    function setReferralFee(uint256 _refFee) external {
        require(msg.sender == feeToSetter, 'Toonswap: FORBIDDEN');
        REFERRAL_FEE = _refFee;
    }

    function setTreasuryFee(uint256 _treasuryFee) external {
        require(msg.sender == feeToSetter, 'Toonswap: FORBIDDEN');
        TREASURY_FEE = _treasuryFee;
    }

    function setDibs(address _dibs) external {
        require(msg.sender == feeToSetter, 'Toonswap: FORBIDDEN');
        require(_dibs != address(0), 'address zero');
        dibs = _dibs;
    }

    function setTreasury(address _treasury) external {
        require(msg.sender == feeToSetter, 'Toonswap: FORBIDDEN');
        require(_treasury != address(0), 'Toonswap: ZERO_ADDRESS');
        treasury = _treasury;
    }
}