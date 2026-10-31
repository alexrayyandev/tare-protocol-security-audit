// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {VaultTestBase} from "./VaultTestBase.t.sol";
import {NavCalculator} from "contracts/NavCalculator.sol";
import {ILoans} from "contracts/interfaces/ILoans.sol";
import {INavCalculator} from "contracts/interfaces/INavCalculator.sol";

/**
 * @title TareAudit_M01_PoC
 * @notice Proof of Concept for [M-01]: Asymmetric Discounting of Idle Cash
 * Proves that liquid collected cash sitting in Loans.sol awaiting sweep is discounted
 * by portfolioFactor, but jumps to 100% par value upon calling collectCashflows().
 */
contract TareAudit_M01_PoC is VaultTestBase {
  NavCalculator public realCalculator;

  function setUp() public override {
    super.setUp();

    // Deploy real NavCalculator with default 1.0 (WAD) factors
    uint256[8] memory factors = [WAD, WAD, WAD, WAD, WAD, WAD, WAD, WAD];
    realCalculator = new NavCalculator(address(this), factors);
    realCalculator.grantRole(realCalculator.CALCULATING_AGENT(), address(this));

    // Update vault calculator to real NavCalculator using guardian
    vm.prank(guardian);
    vault.setCalculator(address(realCalculator));

    vm.prank(guardian);
    vault.grantRole(portfolioManagerRole, manager);
  }

  function test_PoC_M01_CashDiscountDiscontinuity() public {
    // 1. Create a loan with collected cashflow (withdrawable investor cash sitting in Loans)
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
    // Cash was discounted by 20% while in Loans, but credited at 100% once inside Vault!
    assertTrue(
      navAfterSweep > navBeforeSweep,
      "NAV must artificially increase after internal cash sweep due to asymmetric cash discounting"
    );

    uint256 jump = navAfterSweep - navBeforeSweep;
    emit log_named_uint("NAV Before Sweep (Cash in Loans discounted by 20%)", navBeforeSweep);
    emit log_named_uint("NAV After Sweep  (Same Cash in Vault counted at 100%)", navAfterSweep);
    emit log_named_uint("Artificial NAV Discontinuity Jump", jump);
  }
}
