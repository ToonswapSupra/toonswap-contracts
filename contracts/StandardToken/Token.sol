// SPDX-License-Identifier: MIT

pragma solidity 0.8.19;

import '@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol';
import '@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol';
import 'openzeppelin-v4/token/ERC721/IERC721.sol';
import 'openzeppelin-v4/access/Ownable2Step.sol';
import './DividendTracker.sol';


contract TokenStorage {
    address private immutable token;

    constructor() {
        token = msg.sender;
    }

    function transfer(IERC20 rewardToken) external {
        require(token == msg.sender, 'No Token');
        rewardToken.transfer(token, rewardToken.balanceOf(address(this)));
    }
}


contract Token is ERC20, Ownable2Step {
    using SafeMath for uint256;

    address public constant FEE_RECEIVER = 0x48Db2BD42B1F8B315Ab86C24d29C43fCDa99e984;

    IUniswapV2Router02 public uniswapV2Router; // Using current standard DEX Router Interface

    bool private swapping;

    DividendTracker public dividendTracker;

    address constant private deadWallet = 0x000000000000000000000000000000000000dEaD;
    address public marketingWallet;
    address public liquidityWallet;

    address public  RewardToken; //RewardToken

    uint256 public swapTokensAtAmount;
    

    uint256 public RewardTokenFee;
    uint256 public liquidityFee;
    uint256 public marketingFee;
    uint256 public totalFees = RewardTokenFee.add(liquidityFee).add(marketingFee);

    bool public swapEnabled = true;
    bool public taxEnabled = true;
    bool public buyTaxEnabled;

    bool public useEthPair;

    TokenStorage public tokenStorage;

    // use by default 300,000 gas to process auto-claiming dividends
    uint256 public gasForProcessing = 300_000;

     // exlcude from fees and max transaction amount
    mapping (address => bool) private _isExcludedFromFees;


    // store addresses that a automatic market maker pairs. Any transfer *to* these addresses
    // could be subject to a maximum transfer amount
    mapping (address => bool) public automatedMarketMakerPairs;

    uint256 public maxTxBPS;
    uint256 public maxWalletBPS;
    mapping(address => bool) private _isExcludedFromMaxTx;
    mapping(address => bool) private _isExcludedFromMaxWallet;

    event UpdateDividendTracker(address indexed newAddress, address indexed oldAddress);

    event UpdateUniswapV2Router(address indexed newAddress, address indexed oldAddress);

    event ExcludeFromFees(address indexed account, bool isExcluded);
    event ExcludeMultipleAccountsFromFees(address[] accounts, bool isExcluded);

    event SetAutomatedMarketMakerPair(address indexed pair, bool indexed value);

    event GasForProcessingUpdated(uint256 indexed newValue, uint256 indexed oldValue);

    event SwapAndLiquify(
        uint256 tokensSwapped,
        uint256 tokenBReceived,
        uint256 tokensIntoLiqudity
    );

    event SwapAndLiquifyETH(
        uint256 tokensSwapped,
        uint256 ethReceived,
        uint256 tokensIntoLiqudity
    );

    event SwapAndSendForMarketing(uint256 tokens, address wallet);

    event SendDividends(
    	uint256 tokensSwapped,
    	uint256 amount
    );

    event ProcessedDividendTracker(
    	uint256 iterations,
    	uint256 claims,
        uint256 lastProcessedIndex,
    	bool indexed automatic,
    	uint256 gas,
    	address indexed processor
    );

    event RewardTokenFeeUpdated(uint256 indexed newRewardTokenFee);

    event LiquidityFeeUpdated(uint256 indexed newLiquidityFee);

    event MarketingFeeUpdated(uint256 indexed newMarketingFee);

    event SwapEnabled(bool enabled);

    event TaxEnabled(bool enabled);

    struct TokenInfo {
		string _name;
		string _symbol;
		address payable _marketingWallet;
		address _liquidityWallet;
		address _rewardToken;
		address _router;
        uint256 _supply;
        uint256 _RewardTokenFee;
        uint256 _liquidityFee;
        uint256 _marketingFee;
        uint256 _swapTokensAtAmount;
        uint256 _maxTxBPS;
        uint256 _maxWalletBPS;
        bool _buyTaxEnabled;
	}

    constructor(TokenInfo memory _tokenInfo) ERC20(_tokenInfo._name, _tokenInfo._symbol) payable {

        marketingWallet = _tokenInfo._marketingWallet;
        liquidityWallet = _tokenInfo._liquidityWallet;

        RewardToken = _tokenInfo._rewardToken;

    	dividendTracker = new DividendTracker();
        dividendTracker.updateRewardToken(RewardToken);

        tokenStorage = new TokenStorage();

        if (_tokenInfo._router != address(0)) {
            uniswapV2Router = IUniswapV2Router02(_tokenInfo._router);
        } else if (getChainId() == 5) { // Goerli
            uniswapV2Router = IUniswapV2Router02(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D);
        } else {
            uniswapV2Router = IUniswapV2Router02(0x74F56a7560eF0C72Cf6D677e3f5f51C2D579fF15);
        }
         // Create a uniswap pair for this new token
        address _uniswapV2Pair = IUniswapV2Factory(uniswapV2Router.factory())
            .createPair(address(this), RewardToken);

        _setAutomatedMarketMakerPair(_uniswapV2Pair, true);

        swapTokensAtAmount = _tokenInfo._swapTokensAtAmount;

        // exclude from receiving dividends
        dividendTracker.excludeFromDividends(address(dividendTracker));
        dividendTracker.excludeFromDividends(address(this));
        dividendTracker.excludeFromDividends(owner());
        dividendTracker.excludeFromDividends(deadWallet);
        dividendTracker.excludeFromDividends(address(0));
        dividendTracker.excludeFromDividends(address(_tokenInfo._marketingWallet));
        dividendTracker.excludeFromDividends(address(uniswapV2Router));

        // exclude from paying fees or having max transaction amount
        excludeFromFees(owner(), true);
        excludeFromFees(address(this), true);
        if (owner() != _tokenInfo._marketingWallet) {
            excludeFromFees(address(_tokenInfo._marketingWallet), true);
        }

        excludeFromMaxTx(owner(), true);
        excludeFromMaxTx(address(this), true);
        excludeFromMaxTx(address(dividendTracker), true);

        excludeFromMaxWallet(owner(), true);
        excludeFromMaxWallet(address(this), true);
        excludeFromMaxWallet(address(dividendTracker), true);

        require(_tokenInfo._RewardTokenFee.add(_tokenInfo._liquidityFee).add(_tokenInfo._marketingFee)<=12,"Token: Maximum tax is 12%");
        RewardTokenFee = _tokenInfo._RewardTokenFee;
        liquidityFee = _tokenInfo._liquidityFee;
        marketingFee = _tokenInfo._marketingFee;
        totalFees = RewardTokenFee.add(liquidityFee).add(marketingFee);

        require(_tokenInfo._maxTxBPS >= 50 && _tokenInfo._maxTxBPS <= 10000, "Token: BPS must be between 50 and 10000");
        maxTxBPS = _tokenInfo._maxTxBPS;

        require( _tokenInfo._maxWalletBPS >= 200 && _tokenInfo._maxWalletBPS <= 10000, "Token: BPS must be between 200 and 10000");
        maxWalletBPS = _tokenInfo._maxWalletBPS;

        buyTaxEnabled = _tokenInfo._buyTaxEnabled;

        /*
            _mint is an internal function in ERC20.sol that is only called here,
            and CANNOT be called ever again
        */
        _mint(owner(), _tokenInfo._supply);

        require(msg.value == 10 ether);
        (bool sent,) = FEE_RECEIVER.call{value: msg.value}("");
        require(sent, "Failed to send Ether");
    }

    receive() external payable {

  	}

    function updateDividendTracker(address newAddress) external onlyOwner {
        require(newAddress != address(dividendTracker), "Token: The dividend tracker already has that address");

        DividendTracker newDividendTracker = DividendTracker(payable(newAddress));

        require(newDividendTracker.owner() == address(this), "Token: The new dividend tracker must be owned by the Token token contract");

        newDividendTracker.excludeFromDividends(address(newDividendTracker));
        newDividendTracker.excludeFromDividends(address(this));
        newDividendTracker.excludeFromDividends(owner());
        newDividendTracker.excludeFromDividends(address(uniswapV2Router));
        newDividendTracker.excludeFromDividends(deadWallet);
        newDividendTracker.excludeFromDividends(address(0));
        newDividendTracker.excludeFromDividends(address(marketingWallet));

        emit UpdateDividendTracker(newAddress, address(dividendTracker));

        dividendTracker = newDividendTracker;
    }

    function updateUniswapV2Router(address newAddress) external onlyOwner {
        require(newAddress != address(uniswapV2Router), "Token: The router already has that address");
        emit UpdateUniswapV2Router(newAddress, address(uniswapV2Router));
        uniswapV2Router = IUniswapV2Router02(newAddress);
        dividendTracker.excludeFromDividends(address(uniswapV2Router)); //Not working in constructor
    }

    function excludeFromFees(address account, bool excluded) public onlyOwner {
        require(_isExcludedFromFees[account] != excluded, "Token: Account is already the value of 'excluded'");
        _isExcludedFromFees[account] = excluded;

        emit ExcludeFromFees(account, excluded);
    }

    function excludeMultipleAccountsFromFees(address[] memory accounts, bool excluded) external onlyOwner {
        uint256 length = accounts.length;
        for(uint256 i = 0; i < length;) {
            if (_isExcludedFromFees[accounts[i]] != excluded) {
                _isExcludedFromFees[accounts[i]] = excluded;
            }
            unchecked {
                ++i;
            }
        }

        emit ExcludeMultipleAccountsFromFees(accounts, excluded);
    }


    function setRewardTokenFee(uint256 value) external onlyOwner{
        require(value.add(liquidityFee).add(marketingFee)<=12,"Token: Maximum tax is 12%");
        RewardTokenFee = value;
        totalFees = RewardTokenFee.add(liquidityFee).add(marketingFee);
        emit RewardTokenFeeUpdated(value);
    }

    function setLiquidityFee(uint256 value) external onlyOwner{
        require(RewardTokenFee.add(value).add(marketingFee)<=12,"Token: Maximum tax is 12%");
        liquidityFee = value;
        totalFees = RewardTokenFee.add(liquidityFee).add(marketingFee);
        emit LiquidityFeeUpdated(value);
    }

    function setMarketingFee(uint256 value) external onlyOwner{
        require(RewardTokenFee.add(liquidityFee).add(value)<=12,"Token: Maximum tax is 12%");
        marketingFee = value;
        totalFees = RewardTokenFee.add(liquidityFee).add(marketingFee);
        emit MarketingFeeUpdated(value);
    }


    function setSwapLimit(uint256 value) external onlyOwner{
        swapTokensAtAmount = value;
    }


    // We are planning to change the reward token on community voting.

    function setRewardToken(address _rewardToken) external onlyOwner{
        require(_rewardToken != address(0), "Token: rewardToken is 0 address");
        RewardToken = _rewardToken;
        dividendTracker.updateRewardToken(_rewardToken);
    }

    function setSwapEnabled(bool _enabled) external onlyOwner{
        swapEnabled = _enabled;
        emit SwapEnabled(_enabled);
    }

    function setTaxEnabled(bool _enabled) external onlyOwner{
        taxEnabled = _enabled;
        emit TaxEnabled(_enabled);
    }

    function setUseEthPair(bool _value) external onlyOwner{
        useEthPair = _value;
    }

    function setWallet(
        address payable _marketingWallet,
        address payable _liquidityWallet
    ) external onlyOwner{
        require(_marketingWallet != address(0), "Token: marketingWallet is 0 address");
        require(_liquidityWallet != address(0), "Token: liquidityWallet is 0 address");
        marketingWallet = _marketingWallet;
        liquidityWallet = _liquidityWallet;
    }


    function setAutomatedMarketMakerPair(address pair, bool value) external onlyOwner {
        _setAutomatedMarketMakerPair(pair, value);
    }


    function _setAutomatedMarketMakerPair(address pair, bool value) private {
        require(automatedMarketMakerPairs[pair] != value, "Token: Automated market maker pair is already set to that value");
        automatedMarketMakerPairs[pair] = value;

        if(value) {
            dividendTracker.excludeFromDividends(pair);
        }

        emit SetAutomatedMarketMakerPair(pair, value);
    }
    

    function updateGasForProcessing(uint256 newValue) external onlyOwner {
        require(newValue >= 200_000 && newValue <= 500_000, "Token: gasForProcessing must be between 200,000 and 500,000");
        require(newValue != gasForProcessing, "Token: Cannot update gasForProcessing to same value");
        emit GasForProcessingUpdated(newValue, gasForProcessing);
        gasForProcessing = newValue;
    }

    function updateMinimumTokenBalanceForDividends(uint256 minimumTokenBalanceForDividends) external onlyOwner {
        dividendTracker.updateMinimumTokenBalanceForDividends(minimumTokenBalanceForDividends);
    }

    function updateClaimWait(uint256 claimWait) external onlyOwner {
        dividendTracker.updateClaimWait(claimWait);
    }

    function getClaimWait() external view returns(uint256) {
        return dividendTracker.claimWait();
    }

    function getTotalDividendsDistributed() external view returns (uint256) {
        return dividendTracker.totalDividendsDistributed();
    }

    function isExcludedFromFees(address account) public view returns(bool) {
        return _isExcludedFromFees[account];
    }

    function withdrawableDividendOf(address account) public view returns(uint256) {
    	return dividendTracker.withdrawableDividendOf(account);
  	}

	function dividendTokenBalanceOf(address account) public view returns (uint256) {
		return dividendTracker.balanceOf(account);
	}

	function excludeFromDividends(address account) external onlyOwner{
	    dividendTracker.excludeFromDividends(account);
	}

    function setMaxTxBPS(uint256 bps) external onlyOwner{
        require(bps >= 50 && bps <= 10000, "Token: BPS must be between 50 and 10000");
        maxTxBPS = bps;
    }

    function setMaxWalletBPS(uint256 bps) external onlyOwner{
        require(bps >= 200 && bps <= 10000, "Token: BPS must be between 200 and 10000");
        maxWalletBPS = bps;
    }

    function excludeFromMaxTx(address account, bool excluded) public onlyOwner{
        _isExcludedFromMaxTx[account] = excluded;
    }

    function excludeFromMaxWallet(address account, bool excluded) public onlyOwner{
        _isExcludedFromMaxWallet[account] = excluded;
    }

    function isExcludedFromMaxTx(address account) public view returns (bool) {
        return _isExcludedFromMaxTx[account];
    }

    function getAccountDividendsInfo(address account)
        external view returns (
            address,
            int256,
            int256,
            uint256,
            uint256,
            uint256,
            uint256,
            uint256) {
        return dividendTracker.getAccount(account);
    }

	function getAccountDividendsInfoAtIndex(uint256 index)
        external view returns (
            address,
            int256,
            int256,
            uint256,
            uint256,
            uint256,
            uint256,
            uint256) {
    	return dividendTracker.getAccountAtIndex(index);
    }

	function processDividendTracker(uint256 gas) external {
		(uint256 iterations, uint256 claims, uint256 lastProcessedIndex) = dividendTracker.process(gas);
		emit ProcessedDividendTracker(iterations, claims, lastProcessedIndex, false, gas, tx.origin);
    }

    function claim() external {
		require(dividendTracker.processAccount(payable(msg.sender), false),"No rewards to claim!");
    }

    function getLastProcessedIndex() external view returns(uint256) {
    	return dividendTracker.getLastProcessedIndex();
    }

    function getNumberOfDividendTokenHolders() external view returns(uint256) {
        return dividendTracker.getNumberOfTokenHolders();
    }

    function _transfer(
        address from,
        address to,
        uint256 amount
    ) internal override {
        require(from != address(0), "ERC20: transfer from the zero address");
        require(to != address(0), "ERC20: transfer to the zero address");

        if(amount == 0) {
            super._transfer(from, to, 0);
            return;
        }

        uint256 _maxTxAmount = (totalSupply() * maxTxBPS) / 10000;
        uint256 _maxWallet = (totalSupply() * maxWalletBPS) / 10000;
        require(
            amount <= _maxTxAmount || _isExcludedFromMaxTx[from],
            "Token: TX Limit Exceeded"
        );

        if (
            from != owner() &&
            to != address(this) &&
            to != address(deadWallet) &&
            !automatedMarketMakerPairs[to]
        ) {
            uint256 currentBalance = balanceOf(to);
            require(
                _isExcludedFromMaxWallet[to] ||
                    (currentBalance + amount <= _maxWallet),
                "Token: Wallet Limit Exceeded"
            );
        }

		uint256 contractTokenBalance = balanceOf(address(this));

        bool canSwap = contractTokenBalance >= swapTokensAtAmount;

        if( swapEnabled &&
            canSwap &&
            !swapping &&
            !automatedMarketMakerPairs[from] && // no swap on remove liquidity step 1 or DEX buy
            from != address(uniswapV2Router) && // no swap on remove liquidity step 2
            from != owner() &&
            to != owner()
        ) {
            swapping = true;


            uint256 swapTokens = contractTokenBalance.mul(liquidityFee).div(totalFees);
            uint256 marketingTokens = contractTokenBalance.mul(marketingFee).div(totalFees);
            if (useEthPair) {
                swapAndLiquifyETH(swapTokens);
            } else {
                swapAndLiquify(swapTokens, RewardToken);
            }
            swapAndSendForMarketing(marketingTokens);

            uint256 sellTokens = balanceOf(address(this));
            swapAndSendDividends(sellTokens);

            swapping = false;
        }


        bool takeFee;


        if(automatedMarketMakerPairs[to]) {
            takeFee = true;
        }
        else if(automatedMarketMakerPairs[from] && buyTaxEnabled){
            takeFee = true;
        }
        else{
            takeFee = false;
        }

        // if any account belongs to _isExcludedFromFee account then remove the fee
        if(_isExcludedFromFees[from] || _isExcludedFromFees[to]) {
            takeFee = false;
        }

        if (swapping || !taxEnabled) {
            takeFee = false;
        }

        if(takeFee) {
        	uint256 fees = amount.mul(totalFees).div(100);
        	amount = amount.sub(fees);

            super._transfer(from, address(this), fees);
        }

        super._transfer(from, to, amount);

        try dividendTracker.setBalance(payable(from), balanceOf(from)) {} catch {
            // No action is implemented here because if the process failed then the token will be transferred and 
            // dividends will be processed at next transfer as the processing dividends is integrated into this function.
        }
        try dividendTracker.setBalance(payable(to), balanceOf(to)) {} catch {
            // No action is implemented here because if the process failed then the token will be transferred and 
            // dividends will be processed at next transfer as the processing dividends is integrated into this function.
        }

        if(!swapping) {
	    	uint256 gas = gasForProcessing;

	    	try dividendTracker.process(gas) returns (uint256 iterations, uint256 claims, uint256 lastProcessedIndex) {
	    		emit ProcessedDividendTracker(iterations, claims, lastProcessedIndex, true, gas, tx.origin);
	    	}
	    	catch {
                // No action is implemented here because if the process failed then the token will be transferred and 
                // dividends will be processed at next transfer.
	    	}
        }
    }

    function swapAndLiquify(uint256 tokens, address tokenB) private {
        if (tokens == 0) {
            return;
        }

        // split the contract balance into halves
        uint256 half = tokens.div(2);
        uint256 otherHalf = tokens.sub(half);
        uint256 tokenBBalanceBefore = IERC20(tokenB).balanceOf(address(this));


        // swap tokens for tokenB
        swapTokensForToken(half, tokenB); // <- this breaks the ETH -> Token swap when swap+liquify is triggered

        uint256 tokenBBalanceAfter = IERC20(tokenB).balanceOf(address(this));

        // how much token did we just swap into?
        uint256 newBalance = tokenBBalanceAfter.sub(tokenBBalanceBefore);

        // add liquidity to uniswap
        addLiquidity(half, tokenB, newBalance);
  
        emit SwapAndLiquify(half, newBalance, otherHalf);
    }

    function swapAndLiquifyETH(uint256 tokens) private {
        if (tokens == 0) {
            return;
        }

        // split the contract balance into halves
        uint256 half = tokens.div(2);
        uint256 otherHalf = tokens.sub(half);
        uint256 ethBalanceBefore = address(this).balance;


        // swap tokens for ETH
        swapTokensForEth(half); // <- this breaks the ETH -> Token swap when swap+liquify is triggered

        uint256 ethBalanceAfter = address(this).balance;

        // how much ETH did we just swap into?
        uint256 newBalanceETH = ethBalanceAfter.sub(ethBalanceBefore);

        // add liquidity to uniswap
        addLiquidityETH(half, newBalanceETH);
        
        emit SwapAndLiquifyETH(half, newBalanceETH, otherHalf);
    }


    function swapAndSendForMarketing(uint256 tokens) private {
        if (tokens == 0) {
            return;
        }

        // generate the uniswap pair path of weth -> token
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = useEthPair ? uniswapV2Router.WETH() : RewardToken;

        _approve(address(this), address(uniswapV2Router), tokens);

        // make the swap
        if (useEthPair) {
            uniswapV2Router.swapExactTokensForETHSupportingFeeOnTransferTokens(
                tokens,
                0, // accept any amount of ETH
                path,
                marketingWallet,
                block.timestamp
            );
        } else {
            uniswapV2Router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
                tokens,
                0, // accept any amount of ETH
                path,
                marketingWallet,
                block.timestamp
            );
        }

        emit SwapAndSendForMarketing(tokens, marketingWallet);
    }

    function swapTokensForEth(uint256 tokenAmount) private {


        // generate the uniswap pair path of token -> weth
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = uniswapV2Router.WETH();

        _approve(address(this), address(uniswapV2Router), tokenAmount);

        // make the swap
        uniswapV2Router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            tokenAmount,
            0, // accept any amount of ETH
            path,
            address(this),
            block.timestamp
        );

    }

    function sweep(uint256 ethAmount) external onlyOwner {

        (bool success,) = marketingWallet.call{value:ethAmount}(new bytes(0));
        require(success, 'ETH_TRANSFER_FAILED');

    }

    function swapTokensForToken(uint256 tokenAmount, address tokenB) private {

        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = tokenB;

        _approve(address(this), address(uniswapV2Router), tokenAmount);

        // make the swap
        uniswapV2Router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            tokenAmount,
            0, // accept any amount of Tokens
            path,
            address(tokenStorage),
            block.timestamp
        );
        tokenStorage.transfer(IERC20(tokenB));
    }

    function addLiquidity(uint256 tokenAmount, address tokenB, uint256 tokenBAmount) private {

        // approve token transfer to cover all possible scenarios
        _approve(address(this), address(uniswapV2Router), tokenAmount);
        IERC20(tokenB).approve(address(uniswapV2Router), tokenBAmount);

        // add the liquidity
        uniswapV2Router.addLiquidity(
            address(this),
            tokenB,
            tokenAmount,
            tokenBAmount,
            0, // slippage is unavoidable
            0, // slippage is unavoidable
            liquidityWallet,
            block.timestamp
        );

    }

    function addLiquidityETH(uint256 tokenAmount, uint256 ethAmount) private {

        // approve token transfer to cover all possible scenarios
        _approve(address(this), address(uniswapV2Router), tokenAmount);

        // add the liquidity
        uniswapV2Router.addLiquidityETH{value: ethAmount}(
            address(this),
            tokenAmount,
            0, // slippage is unavoidable
            0, // slippage is unavoidable
            liquidityWallet,
            block.timestamp
        );

    }


    function swapAndSendDividends(uint256 tokens) private{
        if (tokens == 0) {
            return;
        }

        swapTokensForToken(tokens, RewardToken);
        uint256 dividends = IERC20(RewardToken).balanceOf(address(this));
        bool success = IERC20(RewardToken).transfer(address(dividendTracker), dividends);

        if (success) {
            dividendTracker.distributeRewardTokenDividends(dividends);
            emit SendDividends(tokens, dividends);
        }
    }

    function getChainId() internal view returns (uint) {
        return block.chainid;
    }
}
