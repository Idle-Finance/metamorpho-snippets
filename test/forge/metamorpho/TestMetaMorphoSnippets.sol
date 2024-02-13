// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {MetaMorphoSnippets} from "@snippets/metamorpho/MetaMorphoSnippets.sol";
import "@metamorpho-test/helpers/IntegrationTest.sol";

import {SafeCast} from "@openzeppelin/utils/math/SafeCast.sol";

contract TestMetaMorphoSnippets is IntegrationTest {
    using MorphoBalancesLib for IMorpho;
    using MorphoLib for IMorpho;
    using MathLib for uint256;
    using Math for uint256;
    using MarketParamsLib for MarketParams;

    MetaMorphoSnippets internal snippets;

    function setUp() public virtual override {
        super.setUp();

        snippets = new MetaMorphoSnippets(address(morpho));

        _setCap(allMarkets[0], CAP);
        _sortSupplyQueueIdleLast();

        vm.startPrank(SUPPLIER);
        ERC20(vault.asset()).approve(address(snippets), type(uint256).max);
        vault.approve(address(snippets), type(uint256).max);
        vm.stopPrank();
    }

    function testSupplyAPR0(Market memory market) public {
        vm.assume(market.lastUpdate > 0);
        vm.assume(market.fee < 1 ether);
        vm.assume(market.totalSupplyAssets >= market.totalBorrowAssets);
        // assume no borrowed assets
        market.totalBorrowAssets = 0;

        MarketParams memory _marketParams = allMarkets[0];
        (uint256 totalSupplyAssets,, uint256 totalBorrowAssets,) = morpho.expectedMarketBalances(_marketParams);

        uint256 borrowTrue = irm.borrowRateView(_marketParams, market);
        uint256 utilization = totalBorrowAssets == 0 ? 0 : totalBorrowAssets.wDivUp(totalSupplyAssets);

        assertEq(utilization, 0, "Diff in snippets vs integration supplyAPR test");
        assertEq(
            borrowTrue.wMulDown(1 ether - market.fee).wMulDown(utilization),
            0,
            "Diff in snippets vs integration supplyAPR test"
        );
        assertEq(snippets.supplyAPRMarket(_marketParams, market), 0, "Diff in snippets vs integration supplyAPR test");
    }

    function testSupplyAPRIdleMarket() public {
        Market memory market;
        MarketParams memory idleMarket;
        idleMarket.loanToken = address(loanToken);

        vm.prank(MORPHO_OWNER);
        morpho.enableIrm(address(0));

        morpho.createMarket(idleMarket);

        uint256 supplyAPR = snippets.supplyAPRMarket(idleMarket, market);

        assertEq(supplyAPR, 0, "supply APR");
    }

    function testSupplyAPRMarket(Market memory market, uint64 add, uint64 sub) public {
        vm.assume(market.totalBorrowAssets > 0);
        vm.assume(market.totalBorrowShares > 0);
        vm.assume(market.totalSupplyAssets > 0);
        vm.assume(market.totalSupplyShares > 0);
        vm.assume(market.fee < 1 ether);
        vm.assume(market.totalSupplyAssets >= market.totalBorrowAssets);

        MarketParams memory _marketParams = allMarkets[0];
        (uint256 totalSupplyAssets,, uint256 totalBorrowAssets,) = morpho.expectedMarketBalances(_marketParams);

        uint256 borrowTrue = irm.borrowRateView(_marketParams, market);
        uint256 utilization = totalBorrowAssets == 0 ? 0 : totalBorrowAssets.wDivUp(totalSupplyAssets);
        uint256 supplyTrue = borrowTrue.wMulDown(1 ether - market.fee).wMulDown(utilization);

        uint256 supplyToTest = snippets.supplyAPRMarket(_marketParams, market);

        // handling in if-else the situation where utilization = 0 otherwise too many rejects
        if (utilization == 0) {
            assertEq(supplyTrue, 0, "supply rate == 0");
            assertEq(supplyTrue, supplyToTest, "Diff in snippets vs integration supplyAPR test");
        } else {
            assertGt(supplyTrue, 0, "supply rate == 0");
            assertEq(supplyTrue, supplyToTest, "Diff in snippets vs integration supplyAPR test");
        }

        // Add/sub assertions
        if (utilization == 0) {
            return;
        }

        uint256 supplyToTestAddSub = snippets.supplyAPRMarket(_marketParams, market, 0, 0);
        assertEq(supplyToTestAddSub, supplyToTest, "Diff in supplyAPRVault without add/sub values");

        supplyToTestAddSub = snippets.supplyAPRMarket(_marketParams, market, add, sub);
        // update market totalSupplyAssets
        market.totalSupplyAssets = uint128(uint256(market.totalSupplyAssets) + add - sub);
        borrowTrue = irm.borrowRateView(_marketParams, market);
        utilization = totalBorrowAssets == 0 ? 0 : totalBorrowAssets.wDivUp(totalSupplyAssets + add - sub);
        supplyTrue = borrowTrue.wMulDown(1 ether - market.fee).wMulDown(utilization);
        assertEq(supplyToTestAddSub, supplyTrue, "Diff in supplyAPRVault with add/sub values");
    }

    function testSupplyAPRVault(uint256 firstDeposit, uint256 secondDeposit, uint256 firstBorrow, uint256 secondBorrow, uint256 add, uint256 sub) public
    {
        firstDeposit = bound(firstDeposit, MIN_TEST_ASSETS, MAX_TEST_ASSETS / 2);
        secondDeposit = bound(secondDeposit, MIN_TEST_ASSETS, MAX_TEST_ASSETS / 2);
        firstBorrow = bound(firstBorrow, MIN_TEST_ASSETS, firstDeposit);
        secondBorrow = bound(secondBorrow, MIN_TEST_ASSETS, secondDeposit);
        add = bound(add, MIN_TEST_ASSETS, MAX_TEST_ASSETS / 2);
        sub = bound(sub, MIN_TEST_ASSETS, MAX_TEST_ASSETS / 2);       

        _setupVault(firstDeposit, secondDeposit, firstBorrow, secondBorrow);

        Id id0 = Id(allMarkets[0].id());
        Id id1 = Id(allMarkets[1].id());

        // Calc vault apr using 0 add/sub
        uint256 expectedAvgRate = _calcVaultAPR(id0, id1, firstDeposit, secondDeposit, 0, 0);
        uint256 avgSupplyRateSnippets = snippets.supplyAPRVault(address(vault));

        assertApproxEqAbs(avgSupplyRateSnippets, expectedAvgRate, 100, "avgSupplyRateSnippets == 0");

        // Add/sub assertions
        if (add >= sub) {
            add = add - sub;
            sub = 0;
        } else {
            sub = sub - add;
            add = 0;
        }

        // Result should be the same if 0 add/sub
        assertApproxEqAbs(snippets.supplyAPRVault(address(vault), 0, 0), avgSupplyRateSnippets, 100, "Diff in supplyAPRVault without add/sub values");

        // Result should match the same if add/sub != 0
        avgSupplyRateSnippets = snippets.supplyAPRVault(address(vault), add, sub);
        expectedAvgRate = _calcVaultAPR(id0, id1, firstDeposit, secondDeposit, add, sub);

        // Check that the amount we want to redeem is actually available
        uint256 maxWithdrawable = vault.maxWithdraw(ONBEHALF);
        if (sub > maxWithdrawable) {
            expectedAvgRate = 0;
        }
        assertApproxEqAbs(avgSupplyRateSnippets, expectedAvgRate, 100, "Diff in supplyAPRVault with add/sub values");
    }

    function _setupVault(uint256 firstDeposit, uint256 secondDeposit, uint256 firstBorrow, uint256 secondBorrow) internal {
        _setCap(allMarkets[0], firstDeposit);
        _setCap(allMarkets[1], secondDeposit);

        Id[] memory supplyQueue = new Id[](2);
        supplyQueue[0] = allMarkets[0].id();
        supplyQueue[1] = allMarkets[1].id();

        vm.prank(ALLOCATOR);
        vault.setSupplyQueue(supplyQueue);

        loanToken.setBalance(SUPPLIER, firstDeposit + secondDeposit);
        vm.startPrank(SUPPLIER);
        vault.deposit(firstDeposit, ONBEHALF);
        vault.deposit(secondDeposit, ONBEHALF);
        vm.stopPrank();

        collateralToken.setBalance(BORROWER, 2 * MAX_TEST_ASSETS);
        vm.startPrank(BORROWER);
        morpho.supplyCollateral(allMarkets[0], MAX_TEST_ASSETS, BORROWER, hex"");
        morpho.borrow(allMarkets[0], firstBorrow, 0, BORROWER, BORROWER);

        morpho.supplyCollateral(allMarkets[1], MAX_TEST_ASSETS, BORROWER, hex"");
        morpho.borrow(allMarkets[1], secondBorrow / 4, 0, BORROWER, BORROWER);
        vm.stopPrank();
    }

    function _calcVaultAPR(Id id0, Id id1, uint256 firstDeposit, uint256 secondDeposit, uint256 add, uint256 sub) internal view returns(uint256) {
        uint256 avgRateNum = 
            _calcMarketAprTimesDeposit(allMarkets[0], id0, firstDeposit, add, sub) + 
            _calcMarketAprTimesDeposit(allMarkets[1], id1, secondDeposit, add, sub);

        if (sub > 0 && (firstDeposit + secondDeposit + add) <= sub) {
           return 0; 
        }
        return avgRateNum.mulDivDown(WAD - vault.fee(), (firstDeposit + secondDeposit) + add - sub);
    }

    function _calcMarketAprTimesDeposit(MarketParams memory params, Id _id, uint256 deposit, uint256 add, uint256 sub) internal view returns(uint256) {
        Market memory market = morpho.market(_id);
        if (add > 0) {
            add = _calcMarketAdd(IMetaMorpho(vault), _id, IMetaMorpho(vault).supplyQueueLength(), add);
        }
        if (sub > 0) {
            sub = _calcMarketSub(IMetaMorpho(vault), _id, IMetaMorpho(vault).withdrawQueueLength(), sub);
        }

        if (sub > 0 && (deposit + add) < sub) {
            return 0;
        }
        return snippets.supplyAPRMarket(params, market, add, sub).wMulDown(deposit + add - sub);
    }

    /// @notice calculate how much of vault `_add` amount will be added to this market
    /// @dev copied from MetaMorphoSnippets.sol
    /// @param _mmVault metamorpho vault
    /// @param _targetMarketId target market id
    /// @param _supplyQueueLen supply queue length
    /// @param _add amount of liquidity to add
    function _calcMarketAdd(
        IMetaMorpho _mmVault,
        Id _targetMarketId,
        uint256 _supplyQueueLen,
        uint256 _add
    ) internal view returns (uint256) {
        uint256 _assetsSuppliedByVault;
        uint184 _marketCap;
        Id _currMarketId;
        Market memory _market;
        Position memory _pos;

        // loop throuh supplyQueue, starting from the first market, and see how much will
        // be deposited in target market
        for (uint256 i = 0; i < _supplyQueueLen; i++) {
            _currMarketId = _mmVault.supplyQueue(i);
            _market = morpho.market(_currMarketId);
            _pos = morpho.position(_currMarketId, address(_mmVault));
            _assetsSuppliedByVault = _pos.supplyShares * _market.totalSupplyAssets / _market.totalSupplyShares;
            // get max depositable amount for this market
            _marketCap = _mmVault.config(_currMarketId).cap;
            uint256 _maxDeposit;
            if (_assetsSuppliedByVault < uint256(_marketCap)) {
                _maxDeposit = uint256(_marketCap) - _assetsSuppliedByVault;
            }
            // If this is the target market, return the current _add value, eventually
            // reduced to the max depositable amount
            if (Id.unwrap(_currMarketId) == Id.unwrap(_targetMarketId)) {
                if (_add > _maxDeposit) {
                    _add = _maxDeposit;
                }
                break;
            }
            // If this is not the target market, check if we can deposit all the _add amount
            // in this market, otherwise continue the loop and subtract the max depositable
            if (_add > _maxDeposit) {
                _add -= _maxDeposit;
            } else {
                _add = 0;
                break;
            }
        }

        return _add;
    }

    /// @notice calculate how much of vault `_sub` amount will be removed from target market
    /// @dev copied from MetaMorphoSnippets.sol
    /// @param _mmVault metamorpho vault
    /// @param _targetMarketId target market id
    /// @param _withdrawQueueLen withdraw queue length
    /// @param _sub liquidity to remove
    function _calcMarketSub(
        IMetaMorpho _mmVault, 
        Id _targetMarketId,
        uint256 _withdrawQueueLen,
        uint256 _sub
    ) internal view returns (uint256) {
        Market memory _market;
        Position memory _position;
        Id _currMarketId;
        // loop throuh withdrawQueue, and see how much will be redeemed in target market
        for (uint256 i = 0; i < _withdrawQueueLen; i++) {
            _currMarketId = _mmVault.withdrawQueue(i);
            _market = morpho.market(_currMarketId);
            _position = morpho.position(_currMarketId, address(_mmVault));
            // get available liquidity for this market
            if (_market.totalSupplyShares == 0) {
                continue;
            }
            uint256 _vaultAssets = _position.supplyShares * _market.totalSupplyAssets / _market.totalSupplyShares;
            uint256 _availableLiquidity = _market.totalSupplyAssets - _market.totalBorrowAssets;
            uint256 _withdrawable = _vaultAssets > _availableLiquidity ? _availableLiquidity : _vaultAssets;

            // If this is the target market, return the current _sub value, eventually
            // reduced to the max withdrawable amount
            if (Id.unwrap(_currMarketId) == Id.unwrap(_targetMarketId)) {
                if (_sub > _withdrawable) {
                    _sub = _withdrawable;
                }
                break;
            }
            // If this is not the target market, check if we can withdraw all the _sub amount
            // in this market, otherwise continue the loop and subtract the available liquidity
            if (_sub > _withdrawable) {
                _sub -= _withdrawable;
            } else {
                _sub = 0;
                break;
            }
        }

        return _sub;
    }
}
