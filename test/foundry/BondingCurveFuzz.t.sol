// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Math as OZMath} from "@openzeppelin/contracts/utils/math/Math.sol";
import {BondingCurve} from "../../contracts/BondingCurve.sol";
import {MockV3Aggregator} from "../../contracts/mocks/MockV3Aggregator.sol";

/// @notice Property-based tests for virtual constant-product math (`calculateBuyAmount` / `calculateSellAmount`).
contract BondingCurveFuzzTest is Test {
    BondingCurve internal curve;
    uint256 internal constant VIRTUAL_TOKEN_RESERVE = 1_000_000_000 * 1e18;

    function setUp() public {
        MockV3Aggregator agg = new MockV3Aggregator(8, 300e8);
        curve = new BondingCurve(
            address(this),
            address(uint160(uint256(keccak256("creator")))),
            1_000_000 ether,
            address(0),
            address(agg),
            VIRTUAL_TOKEN_RESERVE
        );
    }

    /// @notice Buy output is non-decreasing in raise amount (same curve state).
    function testFuzz_calculateBuyAmount_monotonic(uint256 rawA, uint256 rawB) public view {
        uint256 cap = curve.maxBuyAmount();
        uint256 a = bound(rawA, 1, cap);
        uint256 b = bound(rawB, 1, cap);
        if (a > b) (a, b) = (b, a);
        if (a == b) return;

        uint256 outA = curve.calculateBuyAmount(a);
        uint256 outB = curve.calculateBuyAmount(b);
        assertLe(outA, outB);
    }

    /// @notice Token out is always strictly below current virtual token reserve for positive input.
    function testFuzz_calculateBuyAmount_belowVirtualY(uint256 raiseAmount) public view {
        uint256 cap = curve.maxBuyAmount();
        raiseAmount = bound(raiseAmount, 1, cap);

        uint256 x = curve.initialVirtualRaise() + curve.totalTokenIn();
        uint256 yVirt = curve.curveK() / x;
        uint256 out = curve.calculateBuyAmount(raiseAmount);
        assertLt(out, yVirt);
    }

    /// @notice Sell gross raise is non-decreasing in token amount (same curve state).
    function testFuzz_calculateSellAmount_monotonic(uint256 rawA, uint256 rawB) public view {
        uint256 y = curve.curveK() / (curve.initialVirtualRaise() + curve.totalTokenIn());
        uint256 a = bound(rawA, 1, y);
        uint256 b = bound(rawB, 1, y);
        if (a > b) (a, b) = (b, a);
        if (a == b) return;

        uint256 outA = curve.calculateSellAmount(a);
        uint256 outB = curve.calculateSellAmount(b);
        assertLe(outA, outB);
    }

    /// @notice `calculateBuyAmount` matches `mulDiv(y, dx, x + dx)` with on-chain virtual reserves.
    function testFuzz_calculateBuyAmount_matchesMulDiv(uint256 raiseAmount) public view {
        uint256 cap = curve.maxBuyAmount();
        raiseAmount = bound(raiseAmount, 1, cap);

        uint256 k = curve.curveK();
        uint256 x = curve.initialVirtualRaise() + curve.totalTokenIn();
        uint256 y = k / x;
        uint256 expected = OZMath.mulDiv(y, raiseAmount, x + raiseAmount);
        assertEq(curve.calculateBuyAmount(raiseAmount), expected);
    }
}
