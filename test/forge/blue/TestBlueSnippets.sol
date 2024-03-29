// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {Id, IMorpho, MarketParams, Market} from "@morpho-blue/interfaces/IMorpho.sol";
import {BlueSnippets} from "@snippets/blue/BlueSnippets.sol";
import {MorphoBalancesLib} from "@morpho-blue/libraries/periphery/MorphoBalancesLib.sol";
import {MarketParamsLib} from "@morpho-blue/libraries/MarketParamsLib.sol";
import {MorphoLib} from "@morpho-blue/libraries/periphery/MorphoLib.sol";
import {MathLib} from "@morpho-blue/libraries/MathLib.sol";
import {SharesMathLib} from "@morpho-blue/libraries/SharesMathLib.sol";

// we need to import everything in there
import "@morpho-blue-test/BaseTest.sol";

contract TestIntegrationSnippets is BaseTest {
    using MathLib for uint256;
    using MathLib for uint128;
    using MathLib for IMorpho;
    using MorphoLib for IMorpho;
    using MorphoBalancesLib for IMorpho;
    using MarketParamsLib for MarketParams;
    using SharesMathLib for uint256;
    // using TestMarketLib for TestMarket;

    uint256 testNumber;

    BlueSnippets internal snippets;

    function setUp() public virtual override {
        super.setUp();
        snippets = new BlueSnippets(address(morpho));
        testNumber = 42;
    }

    function testSupplyAssetUser(uint256 amountSupplied, uint256 amountBorrowed, uint256 timeElapsed, uint256 fee)
        public
    {
        _generatePendingInterest(amountSupplied, amountBorrowed, timeElapsed, fee);

        uint256 expectedSupplyAssets = snippets.supplyAssetsUser(marketParams, address(this));

        morpho.accrueInterest(marketParams);

        uint256 actualSupplyAssets = morpho.supplyShares(id, address(this)).toAssetsDown(
            morpho.totalSupplyAssets(id), morpho.totalSupplyShares(id)
        );

        assertEq(expectedSupplyAssets, actualSupplyAssets);
    }

    function testBorrowAssetUser(uint256 amountSupplied, uint256 amountBorrowed, uint256 timeElapsed, uint256 fee)
        public
    {
        _generatePendingInterest(amountSupplied, amountBorrowed, timeElapsed, fee);

        uint256 expectedBorrowAssets = snippets.borrowAssetsUser(marketParams, address(this));

        morpho.accrueInterest(marketParams);

        uint256 actualBorrowAssets = morpho.borrowShares(id, address(this)).toAssetsUp(
            morpho.totalBorrowAssets(id), morpho.totalBorrowShares(id)
        );

        assertEq(expectedBorrowAssets, actualBorrowAssets);
    }

    function testCollateralAssetUser(uint256 amountSupplied, uint256 amountBorrowed, uint256 timestamp, uint256 fee)
        public
    {
        vm.assume(amountSupplied > 0);
        vm.assume(amountSupplied >= amountBorrowed);
        _testMorphoLibCommon(amountSupplied, amountBorrowed, timestamp, fee);

        uint256 expectedCollateral = snippets.collateralAssetsUser(id, BORROWER);
        assertEq(morpho.collateral(id, BORROWER), expectedCollateral);
    }

    function testMarketTotalSupply(uint256 amountSupplied, uint256 amountBorrowed, uint256 timeElapsed, uint256 fee)
        public
    {
        _generatePendingInterest(amountSupplied, amountBorrowed, timeElapsed, fee);

        uint256 expectedTotalSupply = snippets.marketTotalSupply(marketParams);

        morpho.accrueInterest(marketParams);

        assertEq(expectedTotalSupply, morpho.totalSupplyAssets(id));
    }

    function testMarketTotalBorrow(uint256 amountSupplied, uint256 amountBorrowed, uint256 timeElapsed, uint256 fee)
        public
    {
        _generatePendingInterest(amountSupplied, amountBorrowed, timeElapsed, fee);

        uint256 expectedTotalBorrow = snippets.marketTotalBorrow(marketParams);

        morpho.accrueInterest(marketParams);

        assertEq(expectedTotalBorrow, morpho.totalBorrowAssets(id));
    }

    function testBorrowAPY(Market memory market) public {
        vm.assume(market.totalBorrowAssets > 0);
        vm.assume(market.totalSupplyAssets >= market.totalBorrowAssets);
        uint256 borrowTrue = irm.borrowRate(marketParams, market).wTaylorCompounded(1);
        uint256 borrowToTest = snippets.borrowAPY(marketParams, market);
        assertEq(borrowTrue, borrowToTest, "Diff in snippets vs integration borrowAPY test");
    }

    function testBorrowAPYIdleMarket(Market memory market) public {
        MarketParams memory idleMarket;
        idleMarket.loanToken = address(loanToken);

        uint256 borrowRate = snippets.borrowAPY(idleMarket, market);

        assertEq(borrowRate, 0, "borrow rate");
    }

    function testSupplyAPYEqual0(Market memory market) public {
        vm.assume(market.totalBorrowAssets == 0);
        vm.assume(market.totalSupplyAssets > 100000);
        vm.assume(market.lastUpdate > 0);
        vm.assume(market.fee < 1 ether);
        vm.assume(market.totalSupplyAssets >= market.totalBorrowAssets);

        (uint256 totalSupplyAssets,, uint256 totalBorrowAssets,) = morpho.expectedMarketBalances(marketParams);
        uint256 borrowTrue = irm.borrowRate(marketParams, market).wTaylorCompounded(1);
        uint256 utilization = totalBorrowAssets == 0 ? 0 : totalBorrowAssets.wDivUp(totalSupplyAssets);

        uint256 supplyTrue = borrowTrue.wMulDown(1 ether - market.fee).wMulDown(utilization);
        uint256 supplyToTest = snippets.supplyAPY(marketParams, market);
        assertEq(supplyTrue, 0, "Diff in snippets vs integration supplyAPY test");
        assertEq(supplyToTest, 0, "Diff in snippets vs integration supplyAPY test");
    }

    function testSupplyAPY(Market memory market) public {
        vm.assume(market.totalBorrowAssets > 0);
        vm.assume(market.fee < 1 ether);
        vm.assume(market.totalSupplyAssets >= market.totalBorrowAssets);

        (uint256 totalSupplyAssets,, uint256 totalBorrowAssets,) = morpho.expectedMarketBalances(marketParams);
        uint256 borrowTrue = irm.borrowRateView(marketParams, market);
        uint256 utilization = totalBorrowAssets == 0 ? 0 : totalBorrowAssets.wDivUp(totalSupplyAssets);

        uint256 supplyTrue = borrowTrue.wMulDown(1 ether - market.fee).wMulDown(utilization);
        uint256 supplyToTest = snippets.supplyAPY(marketParams, market);

        assertEq(supplyTrue, supplyToTest, "Diff in snippets vs integration supplyAPY test");
    }

    function testHealthfactor(uint256 amountSupplied, uint256 amountBorrowed, uint256 timeElapsed, uint256 fee)
        public
    {
        uint256 actualHF;

        _generatePendingInterest(amountSupplied, amountBorrowed, timeElapsed, fee);
        morpho.accrueInterest(marketParams);

        uint256 expectedHF = snippets.userHealthFactor(marketParams, id, address(this));

        uint256 collateralPrice = IOracle(marketParams.oracle).price();
        uint256 maxBorrow = morpho.collateral(id, address(this)).mulDivDown(collateralPrice, ORACLE_PRICE_SCALE)
            .wMulDown(marketParams.lltv);

        uint256 borrowed = morpho.expectedBorrowAssets(marketParams, address(this));

        if (borrowed == 0) {
            actualHF = type(uint256).max;
        } else {
            actualHF = maxBorrow.wDivDown(borrowed);
        }
        assertEq(expectedHF, actualHF);
    }

    function testHealthfactor0Borrow(uint256 amountSupplied, uint256 timeElapsed, uint256 fee) public {
        uint256 amountBorrowed = 0;
        _generatePendingInterest(amountSupplied, amountBorrowed, timeElapsed, fee);
        morpho.accrueInterest(marketParams);

        uint256 expectedHF = snippets.userHealthFactor(marketParams, id, address(this));

        assertEq(expectedHF, type(uint256).max);
    }

    // ---- Test Managing Functions ----

    function testSupplyAssets(uint256 amount) public {
        amount = bound(amount, 1, MAX_TEST_AMOUNT);
        loanToken.setBalance(address(snippets), amount);

        (uint256 returnAssets,) = snippets.supply(marketParams, amount, address(snippets));

        assertEq(returnAssets, amount, "returned asset amount");
    }

    function testSupplyCollateral(uint256 amount) public {
        amount = bound(amount, 1, MAX_COLLATERAL_ASSETS);

        collateralToken.setBalance(address(snippets), amount);

        snippets.supplyCollateral(marketParams, amount, address(snippets));

        assertEq(morpho.collateral(id, address(snippets)), amount, "collateral");
    }

    function testWithdrawAmount(uint256 amount) public {
        amount = bound(amount, 1, MAX_TEST_AMOUNT);
        loanToken.setBalance(address(snippets), amount);

        snippets.supply(marketParams, amount, address(snippets));
        (uint256 assetsWithdrawn,) = snippets.withdrawAmount(marketParams, amount, address(snippets));
        assertEq(assetsWithdrawn, amount, "returned asset amount");
    }

    function testWithdraw50Percent(uint256 amount) public {
        amount = bound(amount, 1, MAX_TEST_AMOUNT);
        loanToken.setBalance(address(snippets), amount);

        snippets.supply(marketParams, amount, address(snippets));
        (uint256 assetsWithdrawn,) = snippets.withdraw50Percent(marketParams, address(snippets));
        assertEq(assetsWithdrawn, amount / 2, "returned asset amount");
    }

    function testWithdrawAll(uint256 amount) public {
        amount = bound(amount, 1, MAX_TEST_AMOUNT);
        loanToken.setBalance(address(snippets), amount);

        snippets.supply(marketParams, amount, address(snippets));
        (uint256 assetsWithdrawn,) = snippets.withdrawAll(marketParams, address(snippets));
        assertEq(assetsWithdrawn, amount, "returned asset amount");
        assertEq(morpho.expectedSupplyAssets(marketParams, address(snippets)), 0, "supply assets");
    }

    function testWithdrawCollateral(uint256 amount) public {
        amount = bound(amount, 1, MAX_COLLATERAL_ASSETS);

        collateralToken.setBalance(address(snippets), amount);

        snippets.supplyCollateral(marketParams, amount, address(snippets));
        assertEq(morpho.collateral(id, address(snippets)), amount, "collateral");
        snippets.withdrawCollateral(marketParams, amount, address(snippets));
        assertEq(morpho.collateral(id, address(snippets)), 0, "collateral");
    }

    function testBorrowAssets(
        uint256 amountCollateral,
        uint256 amountSupplied,
        uint256 amountBorrowed,
        uint256 priceCollateral
    ) public {
        (amountCollateral, amountBorrowed, priceCollateral) =
            _boundHealthyPosition(amountCollateral, amountBorrowed, priceCollateral);

        amountSupplied = bound(amountSupplied, amountBorrowed, MAX_TEST_AMOUNT);
        _supply(amountSupplied);

        oracle.setPrice(priceCollateral);

        collateralToken.setBalance(address(snippets), amountCollateral);

        snippets.supplyCollateral(marketParams, amountCollateral, address(snippets));

        (uint256 returnAssets,) = snippets.borrow(marketParams, amountBorrowed, address(snippets));

        assertEq(returnAssets, amountBorrowed, "returned asset amount");
    }

    function testRepayAssets(
        uint256 amountCollateral,
        uint256 amountSupplied,
        uint256 amountBorrowed,
        uint256 priceCollateral
    ) public {
        (amountCollateral, amountBorrowed, priceCollateral) =
            _boundHealthyPosition(amountCollateral, amountBorrowed, priceCollateral);

        amountSupplied = bound(amountSupplied, amountBorrowed, MAX_TEST_AMOUNT);
        _supply(amountSupplied);

        oracle.setPrice(priceCollateral);

        collateralToken.setBalance(address(snippets), amountCollateral);

        snippets.supplyCollateral(marketParams, amountCollateral, address(snippets));

        (uint256 returnAssets,) = snippets.borrow(marketParams, amountBorrowed, address(snippets));
        assertEq(returnAssets, amountBorrowed, "returned asset amount");
        (uint256 returnAssetsRepaid,) = snippets.repayAmount(marketParams, amountBorrowed, address(snippets));
        assertEq(returnAssetsRepaid, amountBorrowed, "returned asset amount");
    }

    function testRepay50Percent(
        uint256 amountCollateral,
        uint256 amountSupplied,
        uint256 amountBorrowed,
        uint256 priceCollateral
    ) public {
        (amountCollateral, amountBorrowed, priceCollateral) =
            _boundHealthyPosition(amountCollateral, amountBorrowed, priceCollateral);

        amountSupplied = bound(amountSupplied, amountBorrowed, MAX_TEST_AMOUNT);
        _supply(amountSupplied);

        oracle.setPrice(priceCollateral);

        collateralToken.setBalance(address(snippets), amountCollateral);

        snippets.supplyCollateral(marketParams, amountCollateral, address(snippets));

        (uint256 returnAssets, uint256 returnBorrowShares) =
            snippets.borrow(marketParams, amountBorrowed, address(snippets));
        assertEq(returnAssets, amountBorrowed, "returned asset amount");

        (, uint256 repaidShares) = snippets.repay50Percent(marketParams, address(snippets));

        assertEq(repaidShares, returnBorrowShares / 2, "returned asset amount");
    }

    function testRepayAll(
        uint256 amountCollateral,
        uint256 amountSupplied,
        uint256 amountBorrowed,
        uint256 priceCollateral
    ) public {
        (amountCollateral, amountBorrowed, priceCollateral) =
            _boundHealthyPosition(amountCollateral, amountBorrowed, priceCollateral);

        amountSupplied = bound(amountSupplied, amountBorrowed, MAX_TEST_AMOUNT);
        _supply(amountSupplied);

        oracle.setPrice(priceCollateral);

        collateralToken.setBalance(address(snippets), amountCollateral);

        snippets.supplyCollateral(marketParams, amountCollateral, address(snippets));

        (uint256 returnAssets,) = snippets.borrow(marketParams, amountBorrowed, address(snippets));
        assertEq(returnAssets, amountBorrowed, "returned asset amount");

        (uint256 repaidAssets,) = snippets.repayAll(marketParams, address(snippets));

        assertEq(repaidAssets, amountBorrowed, "returned asset amount");
    }

    function _generatePendingInterest(uint256 amountSupplied, uint256 amountBorrowed, uint256 blocks, uint256 fee)
        internal
    {
        amountSupplied = bound(amountSupplied, 0, MAX_TEST_AMOUNT);
        amountBorrowed = bound(amountBorrowed, 0, amountSupplied);
        blocks = _boundBlocks(blocks);
        fee = bound(fee, 0, MAX_FEE);

        // Set fee parameters.
        vm.startPrank(OWNER);
        if (fee != morpho.fee(id)) morpho.setFee(marketParams, fee);
        vm.stopPrank();

        if (amountSupplied > 0) {
            loanToken.setBalance(address(this), amountSupplied);
            morpho.supply(marketParams, amountSupplied, 0, address(this), hex"");

            if (amountBorrowed > 0) {
                uint256 collateralPrice = oracle.price();
                collateralToken.setBalance(
                    BORROWER, amountBorrowed.wDivUp(marketParams.lltv).mulDivUp(ORACLE_PRICE_SCALE, collateralPrice)
                );

                vm.startPrank(BORROWER);
                morpho.supplyCollateral(
                    marketParams,
                    amountBorrowed.wDivUp(marketParams.lltv).mulDivUp(ORACLE_PRICE_SCALE, collateralPrice),
                    BORROWER,
                    hex""
                );
                morpho.borrow(marketParams, amountBorrowed, 0, BORROWER, BORROWER);
                vm.stopPrank();
            }
        }

        _forward(blocks);
    }

    function _testMorphoLibCommon(uint256 amountSupplied, uint256 amountBorrowed, uint256 timestamp, uint256 fee)
        private
    {
        // Prepare storage layout with non empty values.

        amountSupplied = bound(amountSupplied, 2, MAX_TEST_AMOUNT);
        amountBorrowed = bound(amountBorrowed, 1, amountSupplied);
        timestamp = bound(timestamp, block.timestamp, type(uint32).max);
        fee = bound(fee, 0, MAX_FEE);

        // Set fee parameters.
        if (fee != morpho.fee(id)) {
            vm.prank(OWNER);
            morpho.setFee(marketParams, fee);
        }

        // Set timestamp.
        vm.warp(timestamp);

        loanToken.setBalance(address(this), amountSupplied);
        morpho.supply(marketParams, amountSupplied, 0, address(this), hex"");

        uint256 collateralPrice = IOracle(marketParams.oracle).price();
        collateralToken.setBalance(
            BORROWER, amountBorrowed.wDivUp(marketParams.lltv).mulDivUp(ORACLE_PRICE_SCALE, collateralPrice)
        );

        vm.startPrank(BORROWER);
        morpho.supplyCollateral(
            marketParams,
            amountBorrowed.wDivUp(marketParams.lltv).mulDivUp(ORACLE_PRICE_SCALE, collateralPrice),
            BORROWER,
            hex""
        );
        morpho.borrow(marketParams, amountBorrowed, 0, BORROWER, BORROWER);
        vm.stopPrank();
    }
}
