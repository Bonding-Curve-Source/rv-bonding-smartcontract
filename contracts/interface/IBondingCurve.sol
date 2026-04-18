// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.20;

interface IBondingCurve {
    event Buy(address indexed buyer, uint256 tokenAmount, uint256 ethAmount);
    event Sell(address indexed seller, uint256 tokenAmount, uint256 ethAmount);
    event LiquidityAdded(address indexed poolAddress, uint256 liquidity);

    function initialize(address token, uint256 initialPrice) external;

    function buy() external payable returns (uint256);

    function sell(uint256 tokenAmount) external returns (uint256);

    function calculateBuyAmount(
        uint256 ethAmount
    ) external view returns (uint256);

    function calculateSellAmount(
        uint256 tokenAmount
    ) external view returns (uint256);

    function getPrice() external view returns (uint256);

    function setSlippage(uint256 buySlippage, uint256 sellSlippage) external;
    
    function config(uint256 tradeFee) external;
}
