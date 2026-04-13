// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.20;

/// @notice Minimal BondingCurve interface used by TokenFactory to keep bytecode smaller.
interface IBondingCurveForFactory {
    /// @notice Initializes curve token and launch state.
    function initialize(address _token) external;

    /// @notice Executes buy path where raise asset is sent directly by buyer.
    function executeBuy(address buyer, uint256 raiseAmount) external payable returns (uint256);

    /// @notice Executes buy path where factory can provide swapped raise ERC20.
    function executeBuy(address buyer, uint256 raiseAmount, bool pullRaiseFromFactory)
        external
        payable
        returns (uint256);

    /// @notice Executes sell path and returns net raise amount.
    function executeSell(address seller, uint256 tokenAmount) external returns (uint256);

    /// @notice Returns current spot price in raise units.
    function getCurrentPriceInToken() external view returns (uint256);

    /// @notice Updates trading fee in basis points.
    function config(uint256 tradeFee) external;

    /// @notice Sets max buy amount in raise base units.
    function setMaxBuyAmount(uint256 _maxBuyAmount) external;

    /// @notice Sets max buy amount in 1e18 fixed-point raise units.
    function setMaxBuyInRaiseAsset(uint256 maxRaiseAsset1e18) external;

    /// @notice Returns max buy amount in 1e18 fixed-point raise units.
    function maxBuyInRaiseAsset1e18() external view returns (uint256);

    /// @notice Sets max sell percentage in basis points.
    function setMaxSellPercent(uint256 _maxSellPercent) external;

    /// @notice Sets max wallet percentage in basis points.
    function setMaxWalletPercent(uint256 _maxWalletPercent) external;
}
