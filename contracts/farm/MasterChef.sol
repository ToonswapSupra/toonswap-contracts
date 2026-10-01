// SPDX-License-Identifier: MIT

pragma solidity >=0.6.12;

import '../libraries/SafeMath.sol';
import '../interfaces/IERC20.sol';
import '../token/SafeERC20.sol';
import '../libraries/Ownable.sol';
import "../token/ToonToken.sol";
import "./SyrupBar.sol";
import '../interfaces/IERC721.sol';
import '../interfaces/INFTController.sol';

// MasterChef is the master of TOON. He can make TOON and he is a fair guy.
//
// Note that it's ownable and the owner wields tremendous power. The ownership
// will be transferred to a governance smart contract once TOON is sufficiently
// distributed and the community can show to govern itself.
//
// Have fun reading it. Hopefully it's bug-free. God bless.
contract MasterChef is Ownable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    // Info of each user.
    struct UserInfo {
        uint256 amount; // How many LP tokens the user has provided.
        uint256 rewardDebt; // Reward debt. See explanation below.
        //
        // We do some fancy math here. Basically, any point in time, the amount of TOONs
        // entitled to a user but is pending to be distributed is:
        //
        //   pending reward = (user.amount * pool.accCakePerShare) - user.rewardDebt
        //
        // Whenever a user deposits or withdraws LP tokens to a pool. Here's what happens:
        //   1. The pool's `accCakePerShare` (and `lastRewardBlock`) gets updated.
        //   2. User receives the pending reward sent to his/her address.
        //   3. User's `amount` gets updated.
        //   4. User's `rewardDebt` gets updated.
    }

    // Info of each pool.
    struct PoolInfo {
        IERC20 lpToken; // Address of LP token contract.
        uint256 allocPoint; // How many allocation points assigned to this pool. CAKEs to distribute per block.
        uint256 lastRewardTime; // Last block time that CAKEs distribution occurs.
        uint256 accCakePerShare; // Accumulated CAKEs per share, times 1e12. See below.
    }

    struct NFTSlot {
        address slot1;
        uint256 tokenId1;
        address slot2;
        uint256 tokenId2;
        address slot3;
        uint256 tokenId3;
    }

    // The TOON TOKEN!
    ToonToken public cake;
    // The SYRUP TOKEN!
    SyrupBar public syrup;
    // Ecosystem funds address.
    address public devaddr;
    // Reserve address.
    address public reserveaddr;
    // SwapMining address
    address public miningaddr;


    // TOON tokens created per second.
    uint256 public cakePerSecond;

    // set a max cake per second, which can never be higher than 1 per second
    uint256 public constant maxCakePerSecond = 1e18;

    // Bonus muliplier for early toon makers.
    uint256 public BONUS_MULTIPLIER = 1;

    // Info of each pool.
    PoolInfo[] public poolInfo;
    // Info of each user that stakes LP tokens.
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;
    // Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint = 0;
    // The block time when TOON mining starts.
    uint256 public startTime;

    // The TOON token max total supply 16,868,000
    uint256 public constant toonMaxSupply = 16_868_000e18;

    mapping(address => mapping(uint256 => NFTSlot)) private _depositedNFT; // user => pid => nft slot;

    INFTController public controller = INFTController(address(0));
    uint public nftBoostRate = 100;

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(
        address indexed user,
        uint256 indexed pid,
        uint256 amount
    );
    event UpdateNFTController(address indexed user, address controller);
    event UpdateNFTBoostRate(address indexed user, uint256 controller);

    constructor(
        ToonToken _cake,
        SyrupBar _syrup,
        address _devaddr,
        address _reserveaddr,
        address _miningaddr,
        uint256 _cakePerSecond,
        uint256 _startTime
    ) public {
        cake = _cake;
        syrup = _syrup;
        devaddr = _devaddr;
        reserveaddr = _reserveaddr;
        miningaddr = _miningaddr;
        cakePerSecond = _cakePerSecond;
        startTime = _startTime;
        totalAllocPoint = 0;
    }

    /* ========== NFT View Functions ========== */

    function getBoost(address _account, uint256 _pid) public view returns (uint256) {
        if (address(controller) == address(0)) return 0;
        NFTSlot memory slot = _depositedNFT[_account][_pid];
        uint boost1 = controller.getBoostRate(slot.slot1, slot.tokenId1);
        uint boost2 = controller.getBoostRate(slot.slot2, slot.tokenId2);
        uint boost3 = controller.getBoostRate(slot.slot3, slot.tokenId3);
        uint boost = boost1 + boost2 + boost3;
        return boost.mul(nftBoostRate).div(100); // boosts from 0% onwards
    }

    function getSlots(address _account, uint256 _pid) public view returns (address, address, address) {
        NFTSlot memory slot = _depositedNFT[_account][_pid];
        return (slot.slot1, slot.slot2, slot.slot3);
    }

    function getTokenIds(address _account, uint256 _pid) public view returns (uint256, uint256, uint256) {
        NFTSlot memory slot = _depositedNFT[_account][_pid];
        return (slot.tokenId1, slot.tokenId2, slot.tokenId3);
    }

    function updateMultiplier(uint256 multiplierNumber) public onlyOwner {
        BONUS_MULTIPLIER = multiplierNumber;
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    mapping(IERC20 => bool) public poolExistence;
    modifier nonDuplicatedLP(IERC20 _lpToken) {
        require(poolExistence[_lpToken] == false, "nonDuplicated: Duplicated LPToken");
        _;
    }
    // Add a new lp to the pool. Can only be called by the owner.
    // XXX DO NOT add the same LP token more than once. Rewards will be messed up if you do.
    function add(
        uint256 _allocPoint,
        IERC20 _lpToken,
        bool _withUpdate
    ) public onlyOwner nonDuplicatedLP(_lpToken){
        if (_withUpdate) {
            massUpdatePools();
        }
        uint256 lastRewardTime =
            block.timestamp > startTime ? block.timestamp : startTime;
        totalAllocPoint = totalAllocPoint.add(_allocPoint);
        poolExistence[_lpToken] = true;
        poolInfo.push(
            PoolInfo({
                lpToken: _lpToken,
                allocPoint: _allocPoint,
                lastRewardTime: lastRewardTime,
                accCakePerShare: 0
            })
        );
    }

    // Update the given pool's TOON allocation point. Can only be called by the owner.
    function set(
        uint256 _pid,
        uint256 _allocPoint,
        bool _withUpdate
    ) public onlyOwner {
        if (_withUpdate) {
            massUpdatePools();
        }
        totalAllocPoint = totalAllocPoint.sub(poolInfo[_pid].allocPoint).add(
            _allocPoint
        );
        poolInfo[_pid].allocPoint = _allocPoint;
    }

    /* ========== NFT External Functions ========== */

    // Depositing of NFTs
    function depositNFT(address _nft, uint256 _tokenId, uint256 _slot, uint256 _pid) public {
        require(controller.isWhitelistedNFT(_nft), "only approved NFTs");
        require(IERC721(_nft).balanceOf(msg.sender) > 0, "user does not have specified NFT");
        UserInfo storage user = userInfo[_pid][msg.sender];
        require(user.amount == 0, "not allowed to deposit");

        IERC721(_nft).transferFrom(msg.sender, address(this), _tokenId);

        NFTSlot memory slot = _depositedNFT[msg.sender][_pid];

        if (_slot == 1) slot.slot1 = _nft;
        else if (_slot == 2) slot.slot2 = _nft;
        else if (_slot == 3) slot.slot3 = _nft;

        if (_slot == 1) slot.tokenId1 = _tokenId;
        else if (_slot == 2) slot.tokenId2 = _tokenId;
        else if (_slot == 3) slot.tokenId3 = _tokenId;

        _depositedNFT[msg.sender][_pid] = slot;
    }

    // Withdrawing of NFTs
    function withdrawNFT(uint256 _slot, uint256 _pid) public {
        address _nft;
        uint256 _tokenId;

        NFTSlot memory slot = _depositedNFT[msg.sender][_pid];

        if (_slot == 1) _nft = slot.slot1;
        else if (_slot == 2) _nft = slot.slot2;
        else if (_slot == 3) _nft = slot.slot3;

        if (_slot == 1) _tokenId = slot.tokenId1;
        else if (_slot == 2) _tokenId = slot.tokenId2;
        else if (_slot == 3) _tokenId = slot.tokenId3;

        if (_slot == 1) slot.slot1 = address(0);
        else if (_slot == 2) slot.slot2 = address(0);
        else if (_slot == 3) slot.slot3 = address(0);

        if (_slot == 1) slot.tokenId1 = uint(0);
        else if (_slot == 2) slot.tokenId2 = uint(0);
        else if (_slot == 3) slot.tokenId3 = uint(0);

        _depositedNFT[msg.sender][_pid] = slot;

        IERC721(_nft).transferFrom(address(this), msg.sender, _tokenId);
    }

    // Return reward multiplier over the given _from to _to block.
    function getMultiplier(uint256 _from, uint256 _to)
        public
        view
        returns (uint256)
    {
        if (cake.totalSupply() >= toonMaxSupply) {
            return 0;
        }

        return _to.sub(_from).mul(BONUS_MULTIPLIER);
    }

    // View function to see pending TOONs on frontend.
    function pendingCake(uint256 _pid, address _user)
        external
        view
        returns (uint256)
    {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accCakePerShare = pool.accCakePerShare;
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (block.timestamp > pool.lastRewardTime && lpSupply != 0) {
            uint256 multiplier =
                getMultiplier(pool.lastRewardTime, block.timestamp);
            uint256 cakeReward =
                multiplier.mul(cakePerSecond).mul(pool.allocPoint).div(
                    totalAllocPoint
                );
            accCakePerShare = accCakePerShare.add(
                cakeReward.mul(1e12).div(lpSupply)
            );
        }
        return user.amount.mul(accCakePerShare).div(1e12).sub(user.rewardDebt);
    }

    // Update reward variables for all pools. Be careful of gas spending!
    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.timestamp <= pool.lastRewardTime) {
            return;
        }
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (lpSupply == 0) {
            pool.lastRewardTime = block.timestamp;
            return;
        }
        uint256 multiplier = getMultiplier(pool.lastRewardTime, block.timestamp);
        uint256 cakeReward =
            multiplier.mul(cakePerSecond).mul(pool.allocPoint).div(
                totalAllocPoint
            );

        // ToonSwap Tokenomics
        // total supply 16,868,000
        // 9.35% team + 4.67% points reward (both to devaddr)
        // xTOON reward 23.37%
        // LP farming 51.41%
        // NFT staking reward 4.67%
        // Ecosystem(Preminted) 6.52%

        cake.mintFor(devaddr, cakeReward.mul(1402).div(10000));
        cake.mintFor(reserveaddr, cakeReward.mul(467).div(10000));

        cake.mintFor(address(syrup), cakeReward.mul(7479).div(10000));
        pool.accCakePerShare = pool.accCakePerShare.add(
            cakeReward.mul(7479).mul(1e12).div(10000).div(lpSupply)
        );
        pool.lastRewardTime = block.timestamp;
    }

    // Deposit LP tokens to MasterChef for TOON allocation.
    function deposit(uint256 _pid, uint256 _amount) public {

        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        updatePool(_pid);
        if (user.amount > 0) {
            uint256 pending =
                user.amount.mul(pool.accCakePerShare).div(1e12).sub(
                    user.rewardDebt
                );
            if (pending > 0) {
                safeCakeTransfer(msg.sender, pending, _pid);
            }
        }
        if (_amount > 0) {
            pool.lpToken.safeTransferFrom(
                address(msg.sender),
                address(this),
                _amount
            );
            user.amount = user.amount.add(_amount);
        }
        user.rewardDebt = user.amount.mul(pool.accCakePerShare).div(1e12);
        emit Deposit(msg.sender, _pid, _amount);
    }

    // Withdraw LP tokens from MasterChef.
    function withdraw(uint256 _pid, uint256 _amount) public {

        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        require(user.amount >= _amount, "withdraw: not good");
        updatePool(_pid);
        uint256 pending =
            user.amount.mul(pool.accCakePerShare).div(1e12).sub(
                user.rewardDebt
            );
        if (pending > 0) {
            safeCakeTransfer(msg.sender, pending, _pid);
        }
        if (_amount > 0) {
            user.amount = user.amount.sub(_amount);
            pool.lpToken.safeTransfer(address(msg.sender), _amount);
        }
        user.rewardDebt = user.amount.mul(pool.accCakePerShare).div(1e12);
        emit Withdraw(msg.sender, _pid, _amount);
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        uint256 amount = user.amount;
        user.amount = 0;
        user.rewardDebt = 0;
        pool.lpToken.safeTransfer(address(msg.sender), amount);
        emit EmergencyWithdraw(msg.sender, _pid, amount);
    }

    // Safe toon transfer function, just in case if rounding error causes pool to not have enough TOONs.
    function safeCakeTransfer(address _to, uint256 _amount, uint256 _pid) internal {
        uint256 boost = 0;
        syrup.safeCakeTransfer(_to, _amount);
        boost = getBoost(_to, _pid).mul(_amount).div(100);
        if (boost > 0) cake.mintFor(_to, boost);
    }

    // Changes cake token reward per second, with a cap of max cake per second
    // Good practice to update pools without messing up the contract
    function setCakePerSecond(uint256 _cakePerSecond) external onlyOwner {
        require(_cakePerSecond <= maxCakePerSecond, "setCakePerSecond: too many TOON!");

        // This MUST be done or pool rewards will be calculated with new cake per second
        // This could unfairly punish small pools that dont have frequent deposits/withdraws/harvests
        massUpdatePools();

        cakePerSecond = _cakePerSecond;
    }

    function setNftController(address _controller) public onlyOwner {
        controller = INFTController(_controller);
        emit UpdateNFTController(msg.sender, _controller);
    }

    function setNftBoostRate(uint256 _rate) public onlyOwner {
        require(_rate > 50 && _rate < 500, "boost must be within range");
        nftBoostRate = _rate;
        emit UpdateNFTBoostRate(msg.sender, _rate);
    }

    // Update devaddr by the previous devaddr.
    function setDevaddr(address _addr) public {
        require(msg.sender == devaddr, "devaddr: wut?");
        devaddr = _addr;
    }

    // Update reserveaddr by the previous reserveaddr.
    function setReserveaddr(address _addr) public {
        require(msg.sender == reserveaddr, "reserveaddr: wut?");
        reserveaddr = _addr;
    }

    // Update trademining contract
    function setMiningaddr(address _addr) external onlyOwner {
        miningaddr = _addr;
    }
}
