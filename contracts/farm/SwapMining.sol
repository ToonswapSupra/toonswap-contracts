// SPDX-License-Identifier: MIT

pragma solidity >=0.6.0 <0.8.0;

import "../libraries/EnumerableSet.sol";
import "../libraries/SafeMath.sol";
import "../libraries/ToonswapLibrary.sol";
import "../interfaces/IERC20.sol";
import "../interfaces/IToonswapFactory.sol";
import "../interfaces/IToonswapPair.sol";
import "../token/ToonToken.sol";
import 'hardhat/console.sol';

interface IOracle {
    function update(address tokenA, address tokenB) external;

    function consult(address tokenIn, uint amountIn, address tokenOut) external view returns (uint amountOut);
}

contract SwapMining is Ownable {
    using SafeMath for uint256;
    using EnumerableSet for EnumerableSet.AddressSet;
    EnumerableSet.AddressSet private _whitelist;

    // MDX tokens created per second
    uint256 public toonPerSecond;
    // The block time when MDX mining starts.
    uint256 public startTime;
    // How many seconds are halved
    uint256 public halvingPeriod = 0;
    // Total allocation points
    uint256 public totalAllocPoint = 0;
    IOracle public oracle;
    // router address
    address public router;
    // factory address
    IToonswapFactory public factory;
    // toontoken address
    ToonToken public toonToken;
    // Calculate price based on AVAX
    address public targetToken;
    // pair corresponding pid
    mapping(address => uint256) public pairOfPid;
    // isBlacklist
    mapping(address => bool) public isBlacklist;

    constructor(
        ToonToken _toonToken,
        IToonswapFactory _factory,
        IOracle _oracle,
        address _router,
        address _targetToken,
        uint256 _toonPerSecond,
        uint256 _startTime
    ) public {
        require(address(_toonToken) != address(0), "illegal address");
        toonToken = _toonToken;
        require(address(_factory) != address(0), "illegal address");
        factory = _factory;
        require(address(_oracle) != address(0), "illegal address");
        oracle = _oracle;
        require(_router != address(0), "illegal address");
        router = _router;
        targetToken = _targetToken;
        toonPerSecond = _toonPerSecond;
        startTime = _startTime;
    }

    struct UserInfo {
        uint256 quantity;       // How many LP tokens the user has provided
        uint256 blockTimestamp;    // Last transaction time
    }

    struct PoolInfo {
        address pair;           // Trading pairs that can be mined
        uint256 quantity;       // Current amount of LPs
        uint256 totalQuantity;  // All quantity
        uint256 allocPoint;     // How many allocation points assigned to this pool
        uint256 allocToonAmount; // How many TOONs
        uint256 lastRewardTime;// Last transaction time
    }

    PoolInfo[] public poolInfo;
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;


    function poolLength() public view returns (uint256) {
        return poolInfo.length;
    }


    function addPair(uint256 _allocPoint, address _pair, bool _withUpdate) public onlyOwner {
        require(_pair != address(0), "_pair is the zero address");
        if (_withUpdate) {
            massMintPools();
        }
        uint256 lastRewardTime = block.timestamp > startTime ? block.timestamp : startTime;
        totalAllocPoint = totalAllocPoint.add(_allocPoint);
        poolInfo.push(PoolInfo({
        pair : _pair,
        quantity : 0,
        totalQuantity : 0,
        allocPoint : _allocPoint,
        allocToonAmount : 0,
        lastRewardTime : lastRewardTime
        }));
        pairOfPid[_pair] = poolLength() - 1;
    }

    // Update the allocPoint of the pool
    function setPair(uint256 _pid, uint256 _allocPoint, bool _withUpdate) public onlyOwner {
        if (_withUpdate) {
            massMintPools();
        }
        totalAllocPoint = totalAllocPoint.sub(poolInfo[_pid].allocPoint).add(_allocPoint);
        poolInfo[_pid].allocPoint = _allocPoint;
    }

    // Set the number of toon produced by each second
    function setToonswapPerSecond(uint256 _newPerSecond) public onlyOwner {
        massMintPools();
        toonPerSecond = _newPerSecond;
    }

    // Only tokens in the whitelist can be mined MDX
    function addWhitelist(address _addToken) public onlyOwner returns (bool) {
        require(_addToken != address(0), "SwapMining: token is the zero address");
        return EnumerableSet.add(_whitelist, _addToken);
    }

    function delWhitelist(address _delToken) public onlyOwner returns (bool) {
        require(_delToken != address(0), "SwapMining: token is the zero address");
        return EnumerableSet.remove(_whitelist, _delToken);
    }

    function getWhitelistLength() public view returns (uint256) {
        return EnumerableSet.length(_whitelist);
    }

    function isWhitelist(address _token) public view returns (bool) {
        return EnumerableSet.contains(_whitelist, _token);
    }

    function getWhitelist(uint256 _index) public view returns (address){
        require(_index <= getWhitelistLength() - 1, "SwapMining: index out of bounds");
        return EnumerableSet.at(_whitelist, _index);
    }

    function setHalvingPeriod(uint256 _period) public onlyOwner {
        halvingPeriod = _period;
    }

    function setRouter(address newRouter) public onlyOwner {
        require(newRouter != address(0), "SwapMining: new router is the zero address");
        router = newRouter;
    }

    function setOracle(IOracle _oracle) public onlyOwner {
        require(address(_oracle) != address(0), "SwapMining: new oracle is the zero address");
        oracle = _oracle;
    }

    // At what phase
    function phase(uint256 blockTimestamp) public view returns (uint256) {
        if (halvingPeriod == 0) {
            return 0;
        }
        if (blockTimestamp > startTime) {
            return (blockTimestamp.sub(startTime).sub(1)).div(halvingPeriod);
        }
        return 0;
    }

    function phase() public view returns (uint256) {
        return phase(block.timestamp);
    }

    function reward(uint256 blockTimestamp) public view returns (uint256) {
        uint256 _phase = phase(blockTimestamp);
        return toonPerSecond.div(2 ** _phase);
    }

    function reward() public view returns (uint256) {
        return reward(block.timestamp);
    }

    // Rewards for the current block
    function getToonReward(uint256 _lastRewardTime) public view returns (uint256) {
        require(_lastRewardTime <= block.timestamp, "SwapMining: must little than the current block timestamp");
        uint256 blockReward = 0;
        uint256 n = phase(_lastRewardTime);
        uint256 m = phase(block.timestamp);
        // If it crosses the cycle
        while (n < m) {
            n++;
            // Get the last timestamp of the previous cycle
            uint256 r = n.mul(halvingPeriod).add(startTime);
            // Get rewards from previous periods
            blockReward = blockReward.add((r.sub(_lastRewardTime)).mul(reward(r)));
            _lastRewardTime = r;
        }
        blockReward = blockReward.add((block.timestamp.sub(_lastRewardTime)).mul(reward(block.timestamp)));
        return blockReward;
    }

    // Update all pools Called when updating allocPoint and setting new seconds
    function massMintPools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            mint(pid);
        }
    }

    function mint(uint256 _pid) public returns (bool) {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.timestamp <= pool.lastRewardTime) {
            return false;
        }
        uint256 blockReward = getToonReward(pool.lastRewardTime);
        if (blockReward <= 0) {
            return false;
        }
        // Calculate the rewards obtained by the pool based on the allocPoint
        uint256 toonReward = blockReward.mul(pool.allocPoint).div(totalAllocPoint);
        // Increase the number of tokens in the current pool
        pool.allocToonAmount = pool.allocToonAmount.add(toonReward);
        pool.lastRewardTime = block.timestamp;
        return true;
    }

    modifier onlyRouter() {
        require(msg.sender == router, "SwapMining: caller is not the router");
        _;
    }

    // swapMining only router
    function swap(address account, address input, address output, uint256 amount) public onlyRouter returns (bool) {
        require(account != address(0), "SwapMining: taker swap account is the zero address");
        require(input != address(0), "SwapMining: taker swap input is the zero address");
        require(output != address(0), "SwapMining: taker swap output is the zero address");

        if (poolLength() <= 0) {
            return false;
        }

        if (!isWhitelist(input) || !isWhitelist(output)) {
            return false;
        }

        if (isBlacklist[account]) {
            return false;
        }

        address pair = ToonswapLibrary.pairFor(address(factory), input, output);
        PoolInfo storage pool = poolInfo[pairOfPid[pair]];
        // If it does not exist or the allocPoint is 0 then return
        if (pool.pair != pair || pool.allocPoint <= 0) {
            return false;
        }

        uint256 quantity = getQuantity(output, amount, targetToken);
        if (quantity <= 0) {
            return false;
        }

        mint(pairOfPid[pair]);

        pool.quantity = pool.quantity.add(quantity);
        pool.totalQuantity = pool.totalQuantity.add(quantity);
        UserInfo storage user = userInfo[pairOfPid[pair]][account];
        user.quantity = user.quantity.add(quantity);
        user.blockTimestamp = block.timestamp;
        return true;
    }

    function getQuantity(address outputToken, uint256 outputAmount, address anchorToken) public view returns (uint256) {
        uint256 quantity = 0;
        if (outputToken == anchorToken) {
            quantity = outputAmount;
        } else if (IToonswapFactory(factory).getPair(outputToken, anchorToken) != address(0)) {
            quantity = IOracle(oracle).consult(outputToken, outputAmount, anchorToken);
        } else {
            uint256 length = getWhitelistLength();
            for (uint256 index = 0; index < length; index++) {
                address intermediate = getWhitelist(index);
                if (factory.getPair(outputToken, intermediate) != address(0) && factory.getPair(intermediate, anchorToken) != address(0)) {
                    uint256 interQuantity = IOracle(oracle).consult(outputToken, outputAmount, intermediate);
                    quantity = IOracle(oracle).consult(intermediate, interQuantity, anchorToken);
                    break;
                }
            }
        }
        return quantity;
    }

    // The user withdraws all the transaction rewards of the pool
    function takerWithdraw() public {
        uint256 userSub;
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            PoolInfo storage pool = poolInfo[pid];
            UserInfo storage user = userInfo[pid][msg.sender];
            if (user.quantity > 0) {
                mint(pid);
                // The reward held by the user in this pool
                uint256 userReward = pool.allocToonAmount.mul(user.quantity).div(pool.quantity);
                pool.quantity = pool.quantity.sub(user.quantity);
                pool.allocToonAmount = pool.allocToonAmount.sub(userReward);
                user.quantity = 0;
                user.blockTimestamp = block.timestamp;
                userSub = userSub.add(userReward);
            }
        }
        if (userSub <= 0) {
            return;
        }
        console.log(userSub);
        toonToken.transfer(msg.sender, userSub);
    }

    // Get rewards from users in the current pool
    function getUserReward(uint256 _pid, address _user) public view returns (uint256, uint256){
        require(_pid <= poolInfo.length - 1, "SwapMining: Not find this pool");
        uint256 userSub;
        PoolInfo memory pool = poolInfo[_pid];
        UserInfo memory user = userInfo[_pid][_user];
        if (user.quantity > 0) {
            uint256 blockReward = getToonReward(pool.lastRewardTime);
            uint256 toonReward = blockReward.mul(pool.allocPoint).div(totalAllocPoint);
            userSub = userSub.add((pool.allocToonAmount.add(toonReward)).mul(user.quantity).div(pool.quantity));
        }
        //Toon available to users, User transaction amount
        return (userSub, user.quantity);
    }

    // Get rewards from users in all pool
    function getTotalUserReward(address _user) public view returns (uint256, uint256){
        uint256 length = poolInfo.length;
        uint256 totalUserReward;
        uint256 totalUserQuantity;

        for (uint256 pid = 0; pid < length; ++pid) {
            PoolInfo memory pool = poolInfo[pid];
            UserInfo memory user = userInfo[pid][_user];
            uint256 userSub;
            if (user.quantity > 0) {
                uint256 blockReward = getToonReward(pool.lastRewardTime);
                uint256 toonReward = blockReward.mul(pool.allocPoint).div(totalAllocPoint);
                userSub = userSub.add((pool.allocToonAmount.add(toonReward)).mul(user.quantity).div(pool.quantity));
            }
            totalUserReward = totalUserReward.add(userSub);
            totalUserQuantity = totalUserQuantity.add(user.quantity);
        }
        //Total Toon available to users, User transaction amount
        return (totalUserReward, totalUserQuantity);
    }

    // Get details of the pool
    function getPoolInfo(uint256 _pid) public view returns (address, address, uint256, uint256, uint256, uint256){
        require(_pid <= poolInfo.length - 1, "SwapMining: Not find this pool");
        PoolInfo memory pool = poolInfo[_pid];
        address token0 = IToonswapPair(pool.pair).token0();
        address token1 = IToonswapPair(pool.pair).token1();
        uint256 toonAmount = pool.allocToonAmount;
        uint256 blockReward = getToonReward(pool.lastRewardTime);
        uint256 toonReward = blockReward.mul(pool.allocPoint).div(totalAllocPoint);
        toonAmount = toonAmount.add(toonReward);
        //token0,token1,Pool remaining reward,Total /Current transaction volume of the pool
        return (token0, token1, toonAmount, pool.totalQuantity, pool.quantity, pool.allocPoint);
    }

    function ownerWithdraw(address _to, uint256 _amount) public onlyOwner {
        safeToonTransfer(_to, _amount);
    }

    function addBlacklist(address _address) external onlyOwner {
        isBlacklist[_address] = true;
    }

    function removeBlacklist(address _address) external onlyOwner {
        isBlacklist[_address] = false;
    }

    function safeToonTransfer(address _to, uint256 _amount) internal {
        uint256 balance = toonToken.balanceOf(address(this));
        if (_amount > balance) {
            _amount = balance;
        }
        toonToken.transfer(_to, _amount);
    }
}
