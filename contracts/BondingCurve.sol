// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./interface/IPancakeRouter02.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math as OZMath} from "@openzeppelin/contracts/utils/math/Math.sol";
import "./interface/IBondingCurveForFactory.sol";

/// @dev Constant-product market maker where x * y = k.
contract BondingCurve is Ownable, ReentrancyGuard, IBondingCurveForFactory {
    using SafeERC20 for IERC20;

    uint256 private constant FEE_DENOMINATOR = 10000;
    /// @notice Set at initialize from token balance on curve
    uint256 public totalTokenSupply;
    /// @notice Virtual reserve on the raise side: `10 ** raiseDecimals` (one full raise-asset unit).
    uint256 public immutable initialVirtualRaise;
    /// @notice Token-side virtual reserve at initialization, expected to match factory `initialSupply`.
    uint256 public immutable virtualTokenReserve;
    /// @notice `10**18` scale used by pricing and buy/sell calculations.
    uint256 public constant tokenScale = 1e18;
    /// @notice Constant product invariant: k = initialVirtualRaise * virtualTokenReserve.
    uint256 public immutable curveK;
    uint256 public immutable targetValue;
    uint256 public constant UPDATE_INTERVAL = 300 seconds;
    /// @dev Reject Chainlink answers older than this (seconds) in `updateParameters` and price views.
    uint256 public constant ORACLE_STALE_SECONDS = 1 hours;
    // Active PancakeSwap V2 addresses on BSC testnet.
    address constant pancakeRouter = 0x0D34BCe358Ec89099466e63f8766D047c8007ba5;
    address constant wbnbAddress = 0xae13d989daC2f0dEbFf460aC112a837C89BAa7cd;

    IERC20 public token;
    /// @notice address(0) = native raise asset (BNB/ETH), otherwise ERC20 raise asset.
    address public immutable tokenRaise;
    uint8 public immutable raiseDecimals;
    uint8 public immutable oracleDecimals;

    address public immutable MainOwner;
    address public immutable Creator;
    bool public tradeDisabled;
    bool public isDex;
    /// @notice Raise target in smallest raise-asset units (native wei or ERC20 base units).
    uint256 public TARGET_TOKEN_BALANCE;
    uint256 public TRADING_FEE = 100;
    AggregatorV3Interface public immutable priceFeed;
    uint256 public lastUpdate;
    /// @notice Total raise amount currently tracked inside the curve branch.
    uint256 public totalTokenIn;
    /// @notice Cached oracle price from the latest update (decimals = oracleDecimals).
    uint256 public tokenPrice;

    // Anti-bot and limit settings (all amounts in raise-asset base units).
    uint256 public launchTime;
    uint256 public constant ANTI_BOT_DURATION = 60;
    uint256 public immutable maxBuyInitialAntiBot;
    /// @notice Max buy amount per trade in raise-asset base units.
    uint256 public maxBuyAmount;
    uint256 public maxSellPercent = 10000;
    uint256 public maxWalletPercent = 10000;
    uint256 public constant CREATOR_FEE_SHARE = 2000;

    event DexListing(address indexed pancakePair, uint256 liquidity, uint256 raiseAmount, uint256 tokenAmount);
    event CurveInitialized(address indexed token, uint256 totalTokenSupply, uint256 launchTime);
    event MaxBuyAmountUpdated(uint256 maxBuyAmount);
    event MaxSellPercentUpdated(uint256 bps);
    event MaxWalletPercentUpdated(uint256 bps);

    constructor(
        address _owner,
        address _creator,
        uint256 _targetValue,
        address _tokenRaise,
        address _priceFeeds,
        uint256 _virtualTokenReserve
    ) Ownable(_owner) {
        // Ownable owner must be TokenFactory, not msg.sender (deployer contract calls constructor).
        require(_owner != address(0), "Zero owner");
        require(_creator != address(0), "Zero creator");
        require(_priceFeeds != address(0), "Zero price feed");
        require(_virtualTokenReserve > 0, "Zero virtual token reserve");
        MainOwner = _owner;
        Creator = _creator;
        tokenRaise = _tokenRaise;
        uint8 rd = _tokenRaise == address(0) ? uint8(18) : IERC20Metadata(_tokenRaise).decimals();
        raiseDecimals = rd;
        initialVirtualRaise = 10 ** uint256(rd);
        virtualTokenReserve = _virtualTokenReserve;
        curveK = OZMath.mulDiv(initialVirtualRaise, virtualTokenReserve, 1);
        priceFeed = AggregatorV3Interface(_priceFeeds);
        oracleDecimals = priceFeed.decimals();
        targetValue = _targetValue;

        // 10 raise-asset units (5e17 in 1e18 fixed-point), scaled to raise decimals.
        maxBuyInitialAntiBot = _raiseAsset1e18ToRaw(1e18);
        // Default max buy is 100 raise-asset units.
        maxBuyAmount = _raiseAsset1e18ToRaw(100 * 1e18);

        updateParameters();
    }

    /// @dev Converts raise amount from 1e18 fixed-point units into on-chain base units.
    function _raiseAsset1e18ToRaw(uint256 amount1e18) internal view returns (uint256) {
        return OZMath.mulDiv(amount1e18, 10 ** uint256(raiseDecimals), 1e18);
    }

    /// @dev Converts raise amount from on-chain base units into 1e18 fixed-point units.
    function _rawToRaiseAsset1e18(uint256 raw) internal view returns (uint256) {
        return OZMath.mulDiv(raw, 1e18, 10 ** uint256(raiseDecimals));
    }

    /// @dev Chainlink `latestRoundData` with round completeness and staleness checks.
    function _latestOraclePrice() private view returns (uint256) {
        (uint80 roundId, int256 answer, , uint256 updatedAt, uint80 answeredInRound) = priceFeed.latestRoundData();
        require(answer > 0, "Invalid oracle price");
        require(answeredInRound >= roundId, "Stale round");
        require(block.timestamp - updatedAt <= ORACLE_STALE_SECONDS, "Stale oracle");
        return uint256(answer);
    }

    /// @notice Updates trading fee in basis points.
    function config(uint256 tradeFee) external onlyOwner {
        TRADING_FEE = tradeFee;
    }

    /// @notice Sets max buy per trade using raise-asset base units.
    function setMaxBuyAmount(uint256 _maxBuyAmount) external onlyOwner {
        require(_maxBuyAmount > 0, "Invalid max buy");
        maxBuyAmount = _maxBuyAmount;
        emit MaxBuyAmountUpdated(_maxBuyAmount);
    }

    /// @notice Sets max buy per trade using 1e18 fixed-point raise-asset units.
    function setMaxBuyInRaiseAsset(uint256 maxRaiseAsset1e18) external onlyOwner {
        require(maxRaiseAsset1e18 > 0, "Invalid max buy");
        maxBuyAmount = _raiseAsset1e18ToRaw(maxRaiseAsset1e18);
        emit MaxBuyAmountUpdated(maxBuyAmount);
    }

    /// @notice Returns current max buy amount in 1e18 fixed-point raise-asset units.
    function maxBuyInRaiseAsset1e18() external view returns (uint256) {
        return _rawToRaiseAsset1e18(maxBuyAmount);
    }

    /// @notice Sets max sell percentage per user transaction in basis points.
    function setMaxSellPercent(uint256 _maxSellPercent) external onlyOwner {
        require(_maxSellPercent > 0 && _maxSellPercent <= FEE_DENOMINATOR, "Invalid max sell");
        maxSellPercent = _maxSellPercent;
        emit MaxSellPercentUpdated(_maxSellPercent);
    }

    /// @notice Sets max wallet holding percentage in basis points.
    function setMaxWalletPercent(uint256 _maxWalletPercent) external onlyOwner {
        require(_maxWalletPercent > 0 && _maxWalletPercent <= FEE_DENOMINATOR, "Invalid max wallet");
        maxWalletPercent = _maxWalletPercent;
        emit MaxWalletPercentUpdated(_maxWalletPercent);
    }

    /// @notice Initializes token address and captures initial token supply.
    function initialize(address _token) external onlyOwner {
        require(address(token) == address(0), "Already initialized");
        token = IERC20(_token);
        totalTokenSupply = IERC20(_token).balanceOf(address(this));
        require(totalTokenSupply > 0, "Zero token balance");
        launchTime = block.timestamp;
        emit CurveInitialized(_token, totalTokenSupply, launchTime);
    }

    /// @notice Refreshes oracle-dependent parameters and target raise threshold.
    function updateParameters() public {
        uint256 p = _latestOraclePrice();
        tokenPrice = p;
        TARGET_TOKEN_BALANCE = OZMath.mulDiv(OZMath.mulDiv(targetValue, 10 ** uint256(oracleDecimals), 1e18), 10 ** uint256(raiseDecimals), p);
        lastUpdate = block.timestamp;
    }

    /// @notice Executes a buy using native or direct ERC20 transfer from buyer.
    function executeBuy(address buyer, uint256 raiseAmount) external payable onlyFactory nonReentrant returns (uint256) {
        return _executeBuy(buyer, raiseAmount, false);
    }

    /// @notice Executes a buy and optionally pulls ERC20 raise from factory.
    /// @param pullRaiseFromFactory True when TokenFactory swapped native into ERC20 and holds the raise asset.
    function executeBuy(address buyer, uint256 raiseAmount, bool pullRaiseFromFactory) external payable onlyFactory nonReentrant returns (uint256) {
        return _executeBuy(buyer, raiseAmount, pullRaiseFromFactory);
    }

    function _executeBuy(address buyer, uint256 raiseAmount, bool pullRaiseFromFactory) private returns (uint256) {
        require(!tradeDisabled, "Trade is disabled");
        require(raiseAmount > 0, "Zero raise amount");
        require(!pullRaiseFromFactory || tokenRaise != address(0), "Bad pull");

        if (tokenRaise == address(0)) {
            require(msg.value >= raiseAmount, "ETH mismatch");
            require(!pullRaiseFromFactory, "No factory pull for native");
        } else {
            if (pullRaiseFromFactory) {
                IERC20(tokenRaise).safeTransferFrom(MainOwner, address(this), raiseAmount);
            } else {
                IERC20(tokenRaise).safeTransferFrom(buyer, address(this), raiseAmount);
            }
        }

        if (block.timestamp <= launchTime + ANTI_BOT_DURATION) {
            require(raiseAmount <= maxBuyInitialAntiBot, "Exceeds anti-bot limit");
        }

        require(raiseAmount <= maxBuyAmount, "Exceeds max buy amount");

        if (block.timestamp - lastUpdate > UPDATE_INTERVAL) updateParameters();

        uint256 tokenOut = calculateBuyAmount(raiseAmount);
        require(tokenOut > 0, "Zero token out");
        uint256 walletCap = OZMath.mulDiv(totalTokenSupply, maxWalletPercent, FEE_DENOMINATOR);
        require(token.balanceOf(buyer) + tokenOut <= walletCap, "Exceeds max wallet");

        totalTokenIn += raiseAmount;
        token.safeTransfer(buyer, tokenOut);

        if (!isDex && totalTokenIn >= TARGET_TOKEN_BALANCE) {
            triggerDEXListing();
        }
        return tokenOut;
    }

    /// @notice Executes a sell and returns net raise amount after fees.
    function executeSell(address seller, uint256 tokenAmount) external onlyFactory nonReentrant returns (uint256) {
        require(!tradeDisabled, "Trade is disabled");
        require(tokenAmount > 0, "Zero token amount");
        require(seller != address(0), "Zero seller");
        uint256 maxAllowed = OZMath.mulDiv(token.balanceOf(seller), maxSellPercent, FEE_DENOMINATOR);
        require(tokenAmount <= maxAllowed, "Exceeds max sell");

        token.safeTransferFrom(seller, address(this), tokenAmount);
        uint256 grossRaise = calculateSellAmount(tokenAmount);
        uint256 fee = OZMath.mulDiv(grossRaise, TRADING_FEE, FEE_DENOMINATOR);
        uint256 netRaise = grossRaise - fee;

        if (tokenRaise == address(0)) {
            require(address(this).balance >= grossRaise, "Insufficient ETH liquidity");
        } else {
            require(IERC20(tokenRaise).balanceOf(address(this)) >= grossRaise, "Insufficient raise liquidity");
        }

        uint256 creatorShare = OZMath.mulDiv(fee, CREATOR_FEE_SHARE, FEE_DENOMINATOR);
        uint256 factoryShare = fee - creatorShare;

        if (totalTokenIn >= grossRaise) {
            totalTokenIn -= grossRaise;
        } else {
            totalTokenIn = 0;
        }

        if (tokenRaise == address(0)) {
            if (creatorShare > 0) {
                payable(Creator).transfer(creatorShare);
            }
            if (factoryShare > 0) {
                payable(MainOwner).transfer(factoryShare);
            }
            payable(seller).transfer(netRaise);
        } else {
            IERC20 raise = IERC20(tokenRaise);
            if (creatorShare > 0) {
                raise.safeTransfer(Creator, creatorShare);
            }
            if (factoryShare > 0) {
                raise.safeTransfer(MainOwner, factoryShare);
            }
            raise.safeTransfer(seller, netRaise);
        }

        return netRaise;
    }

    /// @notice Adds liquidity to PancakeSwap and permanently disables curve trading.
    function triggerDEXListing() private {
        uint256 tokenForLiquidity = token.balanceOf(address(this));
        require(tokenForLiquidity > 0, "No token liquidity");
        token.forceApprove(pancakeRouter, tokenForLiquidity);

        if (tokenRaise == address(0)) {
            uint256 ethForLiquidity = address(this).balance;
            require(ethForLiquidity > 0, "No ETH liquidity");

            (uint256 usedToken, uint256 usedEth, uint256 liquidity) = IPancakeRouter02(pancakeRouter).addLiquidityETH{value: ethForLiquidity}(
                address(token),
                tokenForLiquidity,
                0,
                0,
                MainOwner,
                block.timestamp + 15 minutes
            );

            address pair = pairFor(IPancakeRouter02(pancakeRouter).factory(), address(token), wbnbAddress);
            tradeDisabled = true;
            isDex = true;
            emit DexListing(pair, liquidity, usedEth, usedToken);
        } else {
            IERC20 raise = IERC20(tokenRaise);
            uint256 raiseForLiquidity = raise.balanceOf(address(this));
            require(raiseForLiquidity > 0, "No raise liquidity");
            raise.forceApprove(pancakeRouter, raiseForLiquidity);

            (uint256 amountA, uint256 amountB, uint256 liquidity) = IPancakeRouter02(pancakeRouter).addLiquidity(
                address(token),
                tokenRaise,
                tokenForLiquidity,
                raiseForLiquidity,
                0,
                0,
                MainOwner,
                block.timestamp + 15 minutes
            );

            address pair = pairFor(IPancakeRouter02(pancakeRouter).factory(), address(token), tokenRaise);
            tradeDisabled = true;
            isDex = true;
            // amountA = token meme, amountB = raise ERC20
            emit DexListing(pair, liquidity, amountB, amountA);
        }
    }

    /// @dev CREATE2 pair for RAVI V2 factory (`RaviV2Pair` from @ravi/v2-core — run `yarn init-code-hash` in v2-core after compile).
    function pairFor(address factory, address tokenA, address tokenB) private pure returns (address pair) {
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        pair = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            hex"ff",
                            factory,
                            keccak256(abi.encodePacked(token0, token1)),
                            hex"a1b8e52117ce7caece28872e24cf7706dfbe68e7b516da6afbd3c0bd78a212e1"
                        )
                    )
                )
            )
        );
    }

    /// @notice Returns current virtual raise reserve (x in x*y=k).
    function _virtualRaise() private view returns (uint256) {
        return initialVirtualRaise + totalTokenIn;
    }

    /// @notice Returns current virtual token reserve (y in x*y=k).
    function _virtualToken() private view returns (uint256) {
        uint256 x = _virtualRaise();
        if (x == 0) return 0;
        return curveK / x;
    }

    /// @param raiseAmount Raise amount in base units.
    /// @dev Constant-product output: tokenOut = y * dx / (x + dx), using pre-trade virtual reserves.
    function calculateBuyAmount(uint256 raiseAmount) public view returns (uint256) {
        if (raiseAmount == 0) return 0;
        uint256 x = _virtualRaise();
        uint256 y = _virtualToken();
        if (y == 0) return 0;
        uint256 xAfter = x + raiseAmount;
        return OZMath.mulDiv(y, raiseAmount, xAfter);
    }

    /// @dev Constant-product output for sell before fees: raiseOut = x * dy / (y + dy).
    function calculateSellAmount(uint256 tokenAmount) public view returns (uint256) {
        if (tokenAmount == 0) return 0;
        uint256 x = _virtualRaise();
        uint256 y = _virtualToken();
        if (x == 0 || y == 0) return 0;
        return OZMath.mulDiv(x, tokenAmount, y + tokenAmount);
    }

    /// @notice Returns current spot price in raise base units per token wei, scaled by `tokenScale`.
    function getCurrentPriceInToken() public view returns (uint256) {
        uint256 x = _virtualRaise();
        uint256 y = _virtualToken();
        if (y == 0) return 0;
        return OZMath.mulDiv(x, tokenScale, y);
    }

    /// @notice Returns current token price in USD units aligned to `tokenScale`.
    function getCurrentPriceInUsd() public view returns (uint256) {
        uint256 oracleP = _latestOraclePrice();
        return OZMath.mulDiv(getCurrentPriceInToken(), oracleP, 10 ** uint256(oracleDecimals));
    }

    /// @notice Returns current USD market cap estimate from spot price.
    function getCurrentMarketCapInUsd() public view returns (uint256) {
        return (token.totalSupply() * getCurrentPriceInUsd()) / tokenScale;
    }

    /// @notice Returns curve progress in basis points toward listing threshold.
    function getCurveProgress() public view returns (uint256) {
        if (TARGET_TOKEN_BALANCE == 0) {
            return 0;
        }
        return (totalTokenIn * FEE_DENOMINATOR) / TARGET_TOKEN_BALANCE;
    }

    modifier onlyFactory() {
        require(msg.sender == MainOwner, "Only factory can call this function");
        _;
    }

    receive() external payable {}
}
