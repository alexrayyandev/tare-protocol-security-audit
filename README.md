# Title
Asymmetric portfolio adjustment discounting idle cash in Loans contract will distort PortfolioVault NAV and share price for vault depositors and redeemers

## Summary
Applying the portfolio factor to collected cash in `Loans.sol` before sweeping will cause an artificial NAV discontinuity and economic distortion for vault depositors and redeemers as `PortfolioVault` applies portfolio discounting on idle cash held in `Loans` but treats the exact same cash at par once swept into the vault.

## Root Cause
- In [NavCalculator.sol:86](contracts/NavCalculator.sol#L86), `totalValue` aggregates risk-adjusted principal (`factoredPrincipal`) with risk-free liquid cash (`collectedCash`):
  ```solidity
  totalValue += factoredPrincipal + uint256(collectedCash);
  ```
- In [PortfolioVault.sol:316-320](contracts/PortfolioVault.sol#L316-L320), `updateNav()` applies the portfolio factor across the entire aggregate `pendingNav` without isolating liquid cash:
  ```solidity
  uint256 pendingNav = calculator_.getLoansValue(loansContract, loanIds);
  uint256 adjustedLoans = calculator_.applyPortfolioAdjustment(pendingNav);
  currentNav = adjustedLoans + assetToken.balanceOf(address(this));
  ```
Because `applyPortfolioAdjustment` scales `pendingNav` by `portfolioFactor` (e.g., 0.80), liquid cash in `Loans` is discounted. However, once `collectCashflows()` sweeps this cash into `assetToken.balanceOf(address(this))`, it is valued at 100% par value, producing an immediate artificial spike in NAV and share price purely due to internal fund movement.

## Internal Pre-conditions
1. Calculating Agent sets `portfolioFactor` to be less than `1e18` (e.g. `0.80e18`, representing a 20% portfolio-level risk haircut).
2. A loan tracked in `_navLoanIds` has accrued withdrawable cash sitting in `Loans.sol` (`investorPrincipalWithdrawable` or `investorInterestWithdrawable` > 0).
3. Vault manager calls `updateNav()` prior to executing `collectCashflows()`.

## External Pre-conditions
None required. This is an internal valuation logic and accounting flaw.

## Attack / Vulnerability Path
1. Borrowers submit principal repayments or interest, accumulating liquid cash in `Loans.sol` attributed to vault-owned loan NFTs.
2. The protocol adjusts risk provisioning by setting `portfolioFactor = 0.80e18`.
3. The manager calls `updateNav()`. Liquid cash awaiting sweep is discounted by 20% along with outstanding principal.
4. An investor whose redemption request is approved during this window has their shares burned against an artificially depressed NAV, receiving fewer assets than the underlying asset pool legitimately backs.
5. The manager or keeper calls `collectCashflows()`, sweeping physical tokens from `Loans` into `PortfolioVault`.
6. The manager calls `updateNav()` on the next cycle. The exact same cash is now held directly in `PortfolioVault`'s ERC20 balance and is credited at 100% par value without discount.
7. NAV jumps instantly, diluting exiting redeemers and granting unearned arbitrage gains to incoming depositors.

## Impact
Vault redeemers suffer economic loss up to the discount margin (e.g. 20% on all unswept cash balances). NAV changes fail to reflect true asset performance, creating an arbitrage window whenever cash sweeps are batched or delayed.

## PoC (Foundry Verified)
Place this test in `test/TareAudit_M01_PoC.t.sol` and run `forge test --match-contract TareAudit_M01_PoC -vv`:

```solidity
// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test, console} from "forge-std/Test.sol";
import {PortfolioVault} from "contracts/PortfolioVault.sol";
import {NavCalculator} from "contracts/NavCalculator.sol";
import {Loans} from "contracts/Loans.sol";
import {LoansNFT} from "contracts/LoansNFT.sol";
import {VaultTestBase} from "test/VaultTestBase.t.sol";

contract TareAudit_M01_PoC is VaultTestBase {
    function test_PoC_M01_CashDiscountDiscontinuity() public {
        // 1. Create a loan with withdrawable investor cash sitting in Loans
        uint64 loanId = _createVaultLoanWithCashflow();

        // 2. Set portfolioFactor to 0.80 WAD (20% portfolio risk discount)
        vm.prank(calculatingAgent);
        realCalculator.setPortfolioFactor(0.80e18);

        // 3. Update NAV before cash sweep
        vm.prank(manager);
        vault.updateNav(10);
        uint256 navBeforeSweep = vault.lastNav();

        // 4. Sweep cash from Loans.sol into PortfolioVault balance
        uint64[] memory loanIds = new uint64[](1);
        loanIds[0] = loanId;
        vm.prank(manager);
        vault.collectCashflows(loanIds, bytes32("poc_sweep"));

        // 5. Update NAV after cash sweep
        vm.warp(block.timestamp + 1 days);
        vm.prank(manager);
        vault.updateNav(10);
        uint256 navAfterSweep = vault.lastNav();

        // 6. Verification: NAV jumps purely due to cash sweep
        console.log("NAV Before Sweep (Cash in Loans discounted by 20%):", navBeforeSweep);
        console.log("NAV After Sweep  (Same Cash in Vault counted at 100%):", navAfterSweep);
        console.log("Artificial NAV Discontinuity Jump:", navAfterSweep - navBeforeSweep);

        assertTrue(navAfterSweep > navBeforeSweep);
    }
}
```

### Foundry Terminal Execution Log:
```text
Ran 1 test for test/TareAudit_M01_PoC.t.sol:TareAudit_M01_PoC
[PASS] test_PoC_M01_CashDiscountDiscontinuity() (gas: 2400998)
Logs:
  NAV Before Sweep (Cash in Loans discounted by 20%): 8072000000
  NAV After Sweep  (Same Cash in Vault counted at 100%): 8190000000
  Artificial NAV Discontinuity Jump: 118000000

Suite result: ok. 1 passed; 0 failed; finished in 514.59ms
```

## Mitigation
Separate liquid collected cash from credit-exposed principal before applying the portfolio adjustment factor:

In `NavCalculator.sol`:
```diff
--- a/contracts/NavCalculator.sol
+++ b/contracts/NavCalculator.sol
@@ -75,7 +75,10 @@ contract NavCalculator is INavCalculator {
-    function getLoansValue(address loansContract, uint256[] calldata loanIds) external view returns (uint256 totalValue) {
+    function getLoansBreakdown(address loansContract, uint256[] calldata loanIds) external view returns (uint256 factoredPrincipal, uint256 collectedCash) {
         // calculate principal and collected cash
-        totalValue = ((remainingPrincipal * principalFactor) / 1e18) + collectedCash;
+        factoredPrincipal = (remainingPrincipal * principalFactor) / 1e18;
+        collectedCash = totalCollectedCash;
     }
```

In `PortfolioVault.sol`:
```diff
--- a/contracts/PortfolioVault.sol
+++ b/contracts/PortfolioVault.sol
@@ -316,3 +316,4 @@ contract PortfolioVault is IPortfolioVault {
-        uint256 pendingNav = calculator_.getLoansValue(loansContract, loanIds);
-        uint256 adjustedLoans = calculator_.applyPortfolioAdjustment(pendingNav);
+        (uint256 factoredPrincipal, uint256 collectedCash) = calculator_.getLoansBreakdown(loansContract, loanIds);
+        uint256 adjustedLoans = calculator_.applyPortfolioAdjustment(factoredPrincipal) + collectedCash;
         currentNav = adjustedLoans + assetToken.balanceOf(address(this));
```
