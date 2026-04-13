// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./Token.sol";
import "./interface/IBondingCurveForFactory.sol";
import "./interface/IBondingCurveDeployer.sol";
import "./interface/IPancakeRouter02.sol";

contract TokenFactory is Ownable {
    using SafeERC20 for IERC20;

    /// @dev PancakeSwap V2 router on the same chain as `BondingCurve`.
    address public constant PANCAKE_ROUTER = 0xD99D1c33F9fC3444f8101754aBC46c52416550D1;
    /// @notice Allowlist for raise assets (address(0) can represent native asset).
    mapping(address => bool) public raiseAllowedTokens;
    uint256 public creationFee;
    uint256 public initialSupply;

    struct TokenInfo {
        string name;
        string symbol;
        address tokenAddress;
        address creator;
        uint256 totalSupply;
        address payable bondingCurve;
        address raiseToken;
        string description;
        string imageUrl;
        string twitter;
        string telegram;
        string website;
    }
    mapping(address => TokenInfo) public tokens;
    /// @notice Chainlink AggregatorV3
    mapping(address => address) public tokenUsdAggregator;
    mapping(bytes32 => bool) private usedSalts;
    mapping(string => bool) public usedSymbols;
    
    uint256 public accumulatedFees;

    /// @notice Dedicated deployer that contains only `new BondingCurve`, set once after deployment.
    address public curveDeployer;

    event TokenCreated(
        address indexed tokenAddress,
        address indexed bondingCurve,
        address indexed creator,
        address raiseToken,
        string name,
        string symbol,
        uint256 targetValue
    );

    event FeeCollected(uint256 amount, address indexed collector);
    event CreationFeeUpdated(uint256 newFee);
    event InitialSupplyUpdated(uint256 newSupply);
    event RaiseTokenAllowed(address indexed token, bool allowed);
    event TokenUsdAggregatorSet(address indexed token, address indexed aggregator);
    event Buy(
        address indexed buyer,
        address indexed tokenAddress,
        uint256 tokenAmount,
        uint256 ethAmount,
        uint256 tokenPrice
    );
    event Sell(
        address indexed seller,
        address indexed tokenAddress,
        uint256 tokenAmount,
        uint256 ethAmount,
        uint256 tokenPrice
    );

    constructor() Ownable(msg.sender) {
        creationFee = 0.001 ether;
        initialSupply = 1_000_000_000 * 1e18;
    }

    /// @notice Sets deployer contract after `BondingCurveDeployer` is deployed. Callable only once.
    function setCurveDeployer(address _deployer) external onlyOwner {
        require(curveDeployer == address(0), "Already set");
        require(_deployer != address(0), "Zero deployer");
        curveDeployer = _deployer;
    }

    /// @notice Updates token creation fee.
    function setCreationFee(uint256 newFee) external onlyOwner {
        creationFee = newFee;
        emit CreationFeeUpdated(newFee);
    }

    /// @notice Updates initial token supply transferred to each new curve.
    function setInitialSupply(uint256 newSupply) external onlyOwner {
        require(newSupply > 0, "Invalid supply");
        initialSupply = newSupply;
        emit InitialSupplyUpdated(newSupply);
    }

    /// @notice Updates raise-asset allowlist status.
    function setRaiseAllowedToken(address token, bool allowed) external onlyOwner {
        raiseAllowedTokens[token] = allowed;
        emit RaiseTokenAllowed(token, allowed);
    }

    /// @param token `address(0)` for native asset feed, otherwise ERC20 raise token address.
    /// @param aggregator Chainlink AggregatorV3 address (set `address(0)` to clear).
    function setTokenAggregator(address token, address aggregator) external onlyOwner {
        tokenUsdAggregator[token] = aggregator;
        emit TokenUsdAggregatorSet(token, aggregator);
    }

    /// Deploys Token + BondingCurve, transfers supply, initializes curve. Keeps createToken stack shallow.
    function _deployTokenAndCurve(
        string memory name,
        string memory symbol,
        uint256 targetValue,
        address tokenRaise
    ) private returns (address tokenAddress, address bondingCurveAddress) {
        Token newToken = new Token(name, symbol, address(this), initialSupply);
        tokenAddress = address(newToken);
        address priceFeed = tokenUsdAggregator[tokenRaise];
        require(priceFeed != address(0), "Missing USD aggregator for raise asset");
        require(raiseAllowedTokens[tokenRaise], "Raise token not allowed");
        address deployer = curveDeployer;
        require(deployer != address(0), "Curve deployer not set");
        bondingCurveAddress = IBondingCurveDeployer(deployer).deployBondingCurve(
            address(this),
            msg.sender,
            targetValue,
            tokenRaise,
            priceFeed,
            initialSupply
        );
        require(bondingCurveAddress != address(0), "Bonding curve deployment failed");
        require(newToken.transfer(bondingCurveAddress, initialSupply), "Initial supply transfer failed");
        IBondingCurveForFactory(bondingCurveAddress).initialize(tokenAddress);
    }

    /// @notice Creates a token and its bonding curve, then stores metadata.
    function createToken(
        string memory name,
        string memory symbol,
        string memory description,
        string memory imageUrl,
        string memory twitter,
        string memory telegram,
        string memory website,
        uint256 targetValue,
        address tokenRaise
    ) external payable {
        require(msg.value >= creationFee, "Insufficient creation fee");
        require(!usedSymbols[symbol], "Symbol already used");
        require(raiseAllowedTokens[tokenRaise], "Raise token not allowed");
        (address tokenAddress, address bondingCurveAddress) = _deployTokenAndCurve(name, symbol, targetValue, tokenRaise);
    
        tokens[tokenAddress] = TokenInfo({
            name: name,
            symbol: symbol,
            tokenAddress: tokenAddress,
            creator: msg.sender,
            totalSupply: initialSupply,
            bondingCurve: payable(bondingCurveAddress),
            raiseToken: tokenRaise,
            description: description,
            imageUrl: imageUrl,
            twitter: twitter,
            telegram: telegram,
            website: website
        });

        usedSymbols[symbol] = true;
        accumulatedFees += creationFee;
        payable(owner()).transfer(creationFee);
        emit TokenCreated(tokenAddress, bondingCurveAddress,msg.sender, tokenRaise, name, symbol, targetValue);
    }

    /// @notice Buys token using native asset where raise amount equals `msg.value`.
    function buyToken(address tokenAddress, uint256 minTokensExpected) external payable {
        _buyToken(tokenAddress, minTokensExpected, msg.value, 0);
    }

    /// @notice Buys token using native asset (`msg.value`) or direct ERC20 raise transfer.
    function buyToken(address tokenAddress, uint256 minTokensExpected, uint256 raiseAmount) external payable {
        _buyToken(tokenAddress, minTokensExpected, raiseAmount, 0);
    }

    /// @notice When raise asset is ERC20, swaps native BNB/ETH to raise token before buying.
    /// @param minCakeFromSwap Minimum ERC20 output from swap to protect against AMM slippage.
    function buyTokenWithBNB(
        address tokenAddress,
        uint256 minTokensExpected,
        uint256 minCakeFromSwap
    ) external payable {
        require(msg.value > 0, "Zero BNB");
        _buyToken(tokenAddress, minTokensExpected, msg.value, minCakeFromSwap);
    }

    function _buyToken(
        address tokenAddress,
        uint256 minTokensExpected,
        uint256 buyAmount,
        uint256 minCakeFromSwap
    ) private {
        require(buyAmount > 0, "Zero buy amount");
        TokenInfo memory info = tokens[tokenAddress];
        require(info.tokenAddress != address(0), "Token does not exist");
        IBondingCurveForFactory curve = IBondingCurveForFactory(info.bondingCurve);
        address raiseToken = info.raiseToken;
        uint256 tokenAmount;
        uint256 raiseForEvent = buyAmount;

        if (raiseToken == address(0)) {
            require(minCakeFromSwap == 0, "Unused min cake");
            require(msg.value >= buyAmount, "Bad native amount");
            tokenAmount = curve.executeBuy{value: buyAmount}(msg.sender, buyAmount);
        } else if (msg.value > 0) {
            require(msg.value == buyAmount, "BNB mismatch");
            require(minCakeFromSwap > 0, "Min cake swap");
            address wbnb = IPancakeRouter02(PANCAKE_ROUTER).WETH();
            address[] memory path = new address[](2);
            path[0] = wbnb;
            path[1] = raiseToken;
            uint256[] memory amounts = IPancakeRouter02(PANCAKE_ROUTER).swapExactETHForTokens{value: buyAmount}(
                minCakeFromSwap,
                path,
                address(this),
                block.timestamp + 15 minutes
            );
            uint256 cakeOut = amounts[amounts.length - 1];
            IERC20(raiseToken).forceApprove(address(curve), cakeOut);
            tokenAmount = curve.executeBuy(msg.sender, cakeOut, true);
            IERC20(raiseToken).forceApprove(address(curve), 0);
            raiseForEvent = cakeOut;
        } else {
            require(minCakeFromSwap == 0, "Unused min cake");
            tokenAmount = curve.executeBuy(msg.sender, buyAmount);
        }
        require(tokenAmount >= minTokensExpected, "Slippage exceeded");
        emit Buy(msg.sender, tokenAddress, tokenAmount, raiseForEvent, curve.getCurrentPriceInToken());
    }

    /// @notice Sells token to bonding curve and receives raise asset.
    function sellToken(
        address tokenAddress,
        uint256 tokenAmount,
        uint256 minETHExpected
    ) external {
        TokenInfo memory info = tokens[tokenAddress];
        require(info.tokenAddress != address(0), "Token does not exist");
        IBondingCurveForFactory c = IBondingCurveForFactory(info.bondingCurve);
        uint256 ethAmount = c.executeSell(msg.sender, tokenAmount);
        require(ethAmount >= minETHExpected, "Slippage exceeded");
        emit Sell(msg.sender, tokenAddress, tokenAmount, ethAmount, c.getCurrentPriceInToken());
    }

    /// @notice Updates trading fee on a bonding curve.
    function configBondingCurve(
        address bondingCurve,
        uint256 tradeFee
    ) external onlyOwner {
        IBondingCurveForFactory(bondingCurve).config(tradeFee);
    }
    
    /// @notice Updates max buy, max sell, and max wallet constraints on a bonding curve.
    function setBondingCurveLimits(
        address bondingCurve,
        uint256 maxBuyAmount,
        uint256 maxSellPercent,
        uint256 maxWalletPercent
    ) external onlyOwner {
        IBondingCurveForFactory curve = IBondingCurveForFactory(bondingCurve);
        curve.setMaxBuyAmount(maxBuyAmount);
        curve.setMaxSellPercent(maxSellPercent);
        curve.setMaxWalletPercent(maxWalletPercent);
    }

    /// @notice Withdraws native balance accumulated by the factory.
    function withdrawFees() external onlyOwner {
        uint256 amount = address(this).balance;
        payable(owner()).transfer(amount);
        emit FeeCollected(amount, owner());
    }

    /// @notice Withdraws ERC20 token balance accumulated by the factory.
    /// @param token ERC20 token address to withdraw.
    function withdrawTokenFees(address token) external onlyOwner {
        require(token != address(0), "Invalid token address");
        IERC20 tokenContract = IERC20(token);
        uint256 amount = tokenContract.balanceOf(address(this));
        require(amount > 0, "No token balance");
        tokenContract.safeTransfer(owner(), amount);
        emit FeeCollected(amount, owner());
    }

    /// @notice Returns metadata for a created token.
    function getTokenInfo(
        address token
    ) external view returns (TokenInfo memory) {
        return tokens[token];
    }

    /// @notice Returns true if symbol has already been used.
    function isSymbolTaken(string memory symbol) public view returns (bool) {
        return usedSymbols[symbol];
    }

    /// @notice Computes CREATE2 address for a given salt and bytecode hash.
    function computeAddress(
        bytes32 salt,
        bytes32 bytecodeHash
    ) public view returns (address) {
       return
            address(
                uint160(
                    uint256(
                        keccak256(
                            abi.encodePacked(
                                bytes1(0xff),
                                address(this),
                                salt,
                                bytecodeHash
                            )
                        )
                    )
                )
            );
    }

    /// @notice Placeholder for deterministic token address prediction.
    function predictTokenAddress(
        string calldata name,
        string calldata symbol,
        address creator
    ) public pure returns (address) {
        name;
        symbol;
        creator;
        return address(0);
    }

    receive() external payable {}
}
