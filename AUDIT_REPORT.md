# Security Audit & Code Review Report: Tare Protocol

**Target**: Tare Protocol (`tare-contracts`)  
**Platform**: Sherlock Audit Contest  
**Auditor**: Alex Rayyan (@alexrayyandev)  
**Date**: October 30, 2026  
**Chains**: Avalanche C-Chain  

---

## Executive Summary

Tare Protocol is an institutional private credit and automated lending protocol incorporating an ERC-7540 asynchronous vault (`PortfolioVault`), a dynamic valuation engine (`NavCalculator`), and tokenized loan ledger accounting (`Loans` and `LoansLedger`).

This audit evaluated contract invariants, state transitions, decimal scaling, and liquidity accounting. A total of 2 verified findings were confirmed through automated and local sandbox test execution:
- **1 Medium**: Asymmetric portfolio discounting on idle cash leading to NAV distortion.
- **1 Low**: ERC-7540 / ERC-7575 event parameter inconsistency.

*(Note: An initial automated hypothesis regarding cross-account balance depletion in `refundBorrower` was rigorously tested in the local Foundry sandbox and confirmed as a FALSE POSITIVE due to strict ledger sub-account mapping in `LoansLedger.sol`. It was discarded from the official claim and documented in the Appendix).*

---

## Detailed Findings

### [M-01] Asymmetric Discounting of Idle Cash in Loans Contract Distorts Portfolio NAV and Share Price

- **Severity**: Medium
- **Target Files**:
  - `contracts/NavCalculator.sol` (lines 68–88)
  - `contracts/PortfolioVault.sol` (lines 313–323)

#### Vulnerability Details
In `NavCalculator.sol`, the portfolio loan valuation is accumulated via `getLoansValue()`:

```solidity
uint256 factoredPrincipal = (uint256(remainingPrincipal) * principalFactor) / 1e18;
totalValue = factoredPrincipal + uint256(collectedCash);
```

Here, `totalValue` aggregates the risk-adjusted remaining principal (`factoredPrincipal`) with the liquid cash already collected from borrowers (`collectedCash`). The collected cash represents risk-free liquid assets held in the `Loans` contract awaiting transfer to the vault.

When `PortfolioVault.updateNav()` queries this value, it applies a portfolio-level adjustment factor across the aggregate return:

```solidity
uint256 pendingNav = calculator_.getLoansValue(loansContract, loanIds);
uint256 adjustedLoans = calculator_.applyPortfolioAdjustment(pendingNav);
uint256 totalNav = adjustedLoans + assetToken.balanceOf(address(this));
```

The function `applyPortfolioAdjustment` scales `pendingNav` by `portfolioFactor` (e.g., 0.80 during a market restructuring or default provisioning event). Because `collectedCash` is bundled into `pendingNav`, liquid cash is also discounted by 20%.

Once `PortfolioVault.collectCashflows()` is called by the servicer or automated keeper, `collectedCash` moves from `Loans` into `PortfolioVault`'s physical balance (`assetToken.balanceOf(address(this))`). At this point, the exact same cash is accounted for at 100% par value without the portfolio factor.

#### Impact
This creates an artificial step-function discontinuity in NAV and share price:
1. Prior to cash sweep: Cash in `Loans` is discounted by `portfolioFactor`.
2. Post cash sweep: Cash in `PortfolioVault` is credited at 100% par value.

Investors redeeming shares immediately before a scheduled cash sweep receive an artificially depressed redemption amount, whereas depositors who enter prior to the sweep capture unearned value when cashflows are swept. NAV changes should reflect real asset performance, not operational timing of internal fund transfers.

#### Proof of Concept (Foundry Verification)
The following test was executed in the official Tare test suite (`test/TareAudit_M01_PoC.t.sol`) on the local test environment:

```solidity
function test_PoC_M01_CashDiscountDiscontinuity() public {
    // 1. Create a loan with withdrawable investor cash sitting in Loans
    uint64 loanId = _createVaultLoanWithCashflow();

    // 2. Set portfolioFactor to 0.80 WAD (20% portfolio risk discount)
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
    assertTrue(navAfterSweep > navBeforeSweep);
}
```

**Foundry Terminal Output**:
```text
Ran 1 test for test/TareAudit_M01_PoC.t.sol:TareAudit_M01_PoC
[PASS] test_PoC_M01_CashDiscountDiscontinuity() (gas: 2400998)
Logs:
  NAV Before Sweep (Cash in Loans discounted by 20%): 8072000000
  NAV After Sweep  (Same Cash in Vault counted at 100%): 8190000000
  Artificial NAV Discontinuity Jump: 118000000

Suite result: ok. 1 passed; 0 failed; 0 skipped; finished in 13.77ms
```

#### Recommended Mitigation
Separate the liquid collected cash component from the risk-bearing loan principal before applying `applyPortfolioAdjustment`:

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

---

### [L-01] Non-Compliant `sender` Argument in ERC-7540 / ERC-7575 `Deposit` Event

- **Severity**: Low
- **Target File**: `contracts/PortfolioVault.sol` (line 1010)

#### Vulnerability Details
In `PortfolioVault._claimDeposit`:

```solidity
emit Deposit(controller, receiver, assets, shares);
```

According to ERC-4626 and its asynchronous extensions ERC-7540/7575, the first indexed argument of the `Deposit` event MUST be `address indexed sender`, representing the direct caller (`msg.sender` / authorized operator). Passing `controller` instead of `msg.sender` deviates from the specification and is inconsistent with `_claimRedeem`, which correctly emits `msg.sender`.

#### Impact
Decentralized indexers (The Graph, Goldsky) and off-chain accounting bridges expecting strict ERC-4626/ERC-7540 event logs will misattribute transaction execution when third-party approved operators perform deposit claims.

#### Recommended Mitigation
Emit `msg.sender` as the first argument in `_claimDeposit`:

```diff
--- a/contracts/PortfolioVault.sol
+++ b/contracts/PortfolioVault.sol
@@ -1010,1 +1010,1 @@
-        emit Deposit(controller, receiver, assets, shares);
+        emit Deposit(msg.sender, receiver, assets, shares);
```

---

## Appendix: Evaluated & Discarded False Positives (Foundry Sandbox Verified)

### [DISCARDED] Cross-Account Balance Depletion in `refundBorrower`
- **Initial Claim**: Servicers calling `refundBorrower` could drain physical tokens backing other loans' principal repayments from the pooled ERC20 balance.
- **Verification Harness**: `test/TareAudit_M02_Check.t.sol` executed on Lenovo host.
- **Sandbox Result**: REVERTED with `InvalidAmount()` and `InsufficientCashBalance()`.
- **Root Cause of Rejection**: Contract `LoansLedger.sol` uses `_getBalanceKey(loanId, ACC_CASH)` which isolates accounting per specific loan. Physical balance cannot be drawn if that specific loan's ledger balance is 0. Confirmed 100% false positive and eliminated from disclosure.
