# Security Audit Notes

## Scope
- `contracts/TokenFactory.sol`
- `contracts/BondingCurve.sol`
- `contracts/Token.sol`
- `contracts/BondingCurveDeployer.sol`
- `contracts/interface/IBondingCurveForFactory.sol`

## Method
- Manual source review focused on access control, fund flow, slippage checks, and lifecycle transitions.
- Basic behavior verification using local Hardhat tests (`test/tokenFactory.test.js`).
- This is a lightweight engineering audit note, not a formal third-party audit.

## Findings

### High
- No high-severity issue identified in the reviewed scope.

### Medium
- **Centralized operational control in factory owner**
  - `TokenFactory` owner can modify key parameters (`creationFee`, `initialSupply`, curve limits, fee config).
  - Impact: strong trust assumption for users and token creators.
  - Recommendation: use multisig + timelock for owner actions in production.

- **Hardcoded DEX assumptions**
  - `BondingCurve` uses hardcoded Pancake router, wrapped native token, and pair init code hash.
  - Impact: deployment to a different chain/router can break listing or pair address computation.
  - Recommendation: make router/WETH/init hash configurable at deployment per environment.

### Low
- **Oracle freshness is not validated**
  - `updateParameters()` checks only `price > 0`, but not stale round timestamp bounds.
  - Impact: outdated oracle values may be used during volatile markets.
  - Recommendation: add staleness checks (`updatedAt`, heartbeat window).

- **Unused/placeholder path in `predictTokenAddress()`**
  - Function currently returns `address(0)`.
  - Impact: potential confusion for integrators expecting deterministic prediction.
  - Recommendation: implement correctly or remove/deprecate to avoid misuse.

## Positive Notes
- Reentrancy protection exists on buy/sell execution paths.
- Clear role separation: only factory can call curve trade functions.
- Slippage guard exists at factory level for buy/sell outputs.
- Curve transitions to DEX listing and disables curve trading after threshold.

## Production Checklist
- Add multisig/timelock governance for owner-only functions.
- Parameterize DEX addresses per environment (testnet/mainnet).
- Implement oracle staleness checks.
- Expand tests for ERC20 raise-token path, anti-bot edge cases, and DEX-listing transition.
- Run static tools (`slither`, `mythril`) and property/fuzz testing before mainnet release.
