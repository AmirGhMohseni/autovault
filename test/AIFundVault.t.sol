// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Test.sol";
import "../contracts/AIFundVault.sol";
import "../contracts/RiskManager.sol";
import "../contracts/FeeModule.sol";
import "../contracts/PriceOracleAdapter.sol";
import "../contracts/TokenizedStockRegistry.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("Mock USDC", "USDC") {
        _mint(msg.sender, 100_000_000e6);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

contract AIFundVaultTest is Test {
    MockUSDC usdc;
    RiskManager riskManager;
    FeeModule feeModule;
    PriceOracleAdapter oracle;
    TokenizedStockRegistry registry;
    AIFundVault vault;

    address admin = address(0xA11CE);
    address alice = address(0xA11CE1);
    address bob = address(0xB0B);

    function setUp() public {
        usdc = new MockUSDC();
        riskManager = new RiskManager(admin);
        feeModule = new FeeModule(admin);
        oracle = new PriceOracleAdapter(admin);
        registry = new TokenizedStockRegistry(admin);

        vault = new AIFundVault(
            IERC20(address(usdc)),
            "AutoVault Test",
            "avTEST",
            admin,
            IRiskManager(address(riskManager)),
            IFeeModule(address(feeModule)),
            ITokenizedStockRegistry(address(registry)),
            IPriceOracle(address(oracle)),
            1_000_000e6, // depositCap
            500_000e6    // perBlockDepositCap
        );

        vm.startPrank(admin);
        riskManager.setParams(address(vault), 1500, 3500, 75, 4000); // 15%/35%/0.75%/40%
        feeModule.setFeeConfig(address(vault), 100, 1500, admin); // 1% mgmt, 15% perf
        vm.stopPrank();

        usdc.transfer(alice, 100_000e6);
        usdc.transfer(bob, 100_000e6);
    }

    function test_firstDepositMintsSharesAtParity() public {
        vm.startPrank(alice);
        usdc.approve(address(vault), 10_000e6);
        uint256 shares = vault.deposit(10_000e6, alice);
        vm.stopPrank();

        assertGt(shares, 0, "should mint shares");
        assertEq(vault.totalNAV(), 10_000e6, "NAV should equal idle USDC deposited");
        // sharePrice18 should be ~1e18 (1:1) right after a single deposit with no trades yet.
        assertApproxEqRel(vault.sharePrice18(), 1e18, 0.01e18);
    }

    function test_depositCapEnforced() public {
        vm.startPrank(alice);
        usdc.approve(address(vault), 2_000_000e6);
        vm.expectRevert("deposit cap exceeded");
        vault.deposit(1_500_000e6, alice);
        vm.stopPrank();
    }

    function test_perBlockDepositCapEnforced() public {
        vm.startPrank(alice);
        usdc.approve(address(vault), 600_000e6);
        vm.expectRevert("per-block cap exceeded");
        vault.deposit(600_000e6, alice);
        vm.stopPrank();
    }

    function test_withdrawInstantWhenIdleLiquiditySufficient() public {
        vm.startPrank(alice);
        usdc.approve(address(vault), 10_000e6);
        vault.deposit(10_000e6, alice);
        uint256 balBefore = usdc.balanceOf(alice);
        vault.withdraw(5_000e6, alice, alice);
        vm.stopPrank();

        assertEq(usdc.balanceOf(alice), balBefore + 5_000e6);
        assertEq(vault.totalNAV(), 5_000e6);
    }

    function test_onlyExecutorCanRebalance() public {
        AutoVaultTypes.TradeInstruction[] memory trades = new AutoVaultTypes.TradeInstruction[](0);
        vm.prank(bob);
        vm.expectRevert();
        vault.executeRebalance(trades, bytes32(0));
    }

    function test_pauseBlocksDeposits() public {
        vm.prank(admin);
        vault.pause();

        vm.startPrank(alice);
        usdc.approve(address(vault), 1_000e6);
        vm.expectRevert();
        vault.deposit(1_000e6, alice);
        vm.stopPrank();
    }

    function test_sharePriceRisesProportionallyAcrossTwoDeposits() public {
        vm.startPrank(alice);
        usdc.approve(address(vault), 10_000e6);
        vault.deposit(10_000e6, alice);
        vm.stopPrank();

        // Simulate NAV growth by directly funding the vault (as if a rebalance realized a
        // gain) — a simplified stand-in for a full rebalance-with-price-appreciation flow,
        // which requires mocking a tokenized stock + oracle price feed (see RiskManager
        // and PriceOracleAdapter tests for that lower-level coverage).
        //vm.prank(admin);
        usdc.transfer(address(vault), 1_000e6);

        vm.startPrank(bob);
        usdc.approve(address(vault), 11_000e6);
        uint256 bobShares = vault.deposit(11_000e6, bob);
        vm.stopPrank();

        // Bob deposited into an appreciated NAV, so he should receive fewer shares per
        // USDC than Alice did (proportional dilution protection).
        assertLt(bobShares, 11_000e6 * 1000, "bob should not get par shares post-appreciation");
    }
}
