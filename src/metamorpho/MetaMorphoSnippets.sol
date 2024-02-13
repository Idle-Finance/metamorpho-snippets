// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IMetaMorpho} from "@metamorpho/interfaces/IMetaMorpho.sol";

import {MarketParamsLib} from "../../lib/metamorpho/lib/morpho-blue/src/libraries/MarketParamsLib.sol";
import {Id, IMorpho, Market, MarketParams, Position} from "../../lib/metamorpho/lib/morpho-blue/src/interfaces/IMorpho.sol";
import {IIrm} from "../../lib/metamorpho/lib/morpho-blue/src/interfaces/IIrm.sol";
import {MorphoBalancesLib} from "../../lib/metamorpho/lib/morpho-blue/src/libraries/periphery/MorphoBalancesLib.sol";
import {MathLib, WAD} from "../../lib/metamorpho/lib/morpho-blue/src/libraries/MathLib.sol";

import {Math} from "@openzeppelin/utils/math/Math.sol";

contract MetaMorphoSnippets {
    using MathLib for uint256;
    using Math for uint256;
    using MarketParamsLib for MarketParams;
    using MorphoBalancesLib for IMorpho;

    IMorpho public immutable morpho;

    constructor(address morphoAddress) {
        morpho = IMorpho(morphoAddress);
    }

    // --- VIEW FUNCTIONS ---

    /// @notice Returns the current APR of the vault on a Morpho Blue market.
    /// @param marketParams The morpho blue market parameters.
    /// @param market The morpho blue market state.
    function supplyAPRMarket(MarketParams memory marketParams, Market memory market)
        public
        view
        returns (uint256 supplyRate)
    {
        supplyRate = supplyAPRMarket(marketParams, market, 0, 0);
    }

    /// @notice Returns the current APR of the vault on a Morpho Blue market.
    /// @param marketParams The morpho blue market parameters.
    /// @param market The morpho blue market state.
    /// @param add The amount to add to the market balance.
    /// @param sub The amount to subtract from the market balance.
    function supplyAPRMarket(MarketParams memory marketParams, Market memory market, uint256 add, uint256 sub)
        public
        view
        returns (uint256 supplyRate)
    {
        // Get the borrow rate
        uint256 borrowRate;
        if (marketParams.irm == address(0) || (sub > 0 && (uint256(market.totalSupplyAssets) + add) <= sub)) {
            return 0;
        } else {
            // simulate change in market total assets
            market.totalSupplyAssets = uint128(uint256(market.totalSupplyAssets) + add - sub);
            borrowRate = IIrm(marketParams.irm).borrowRateView(marketParams, market);
        }

        (uint256 totalSupplyAssets,, uint256 totalBorrowAssets,) = morpho.expectedMarketBalances(marketParams);
        if (sub > 0 && (totalSupplyAssets + add) <= sub) {
            return 0;
        }
        // Get the supply rate using add/sub simulations
        uint256 utilization = totalBorrowAssets == 0 ? 0 : totalBorrowAssets.wDivUp(totalSupplyAssets + add - sub);
        supplyRate = borrowRate.wMulDown(1 ether - market.fee).wMulDown(utilization);
    }

    /// @notice Returns the current APY of a MetaMorpho vault.
    /// @dev It is computed as the sum of all APY of enabled markets weighted by the supply on these markets.
    /// @param vault The address of the MetaMorpho vault.
    function supplyAPRVault(address vault) public view returns (uint256 avgSupplyRate) {
        avgSupplyRate = supplyAPRVault(vault, 0, 0);
    }

    /// @notice Returns the current APY of a MetaMorpho vault.
    /// @dev It is computed as the sum of all APY of enabled markets weighted by the supply on these markets.
    /// @param vault The address of the MetaMorpho vault.
    /// @param add The amount to add to the vault balance.
    /// @param sub The amount to subtract from the vault balance.
    function supplyAPRVault(address vault, uint256 add, uint256 sub) public view returns (uint256 avgSupplyRate) {
        uint256 ratio;
        uint256 expectedSupply;
        uint256 queueLength = IMetaMorpho(vault).withdrawQueueLength();
        uint256 supplyQueueLength = IMetaMorpho(vault).supplyQueueLength();
        uint256 newTotalAmount = IMetaMorpho(vault).totalAssets();
        uint256 totRemoved;

        if (sub > 0 && (newTotalAmount + add) <= sub) {
            // impossible to remove more than the vault has
            return 0;
        }
        // simulate change in vault total assets
        newTotalAmount = newTotalAmount + add - sub;

        for (uint256 i; i < queueLength; ++i) {
            Id idMarket = IMetaMorpho(vault).withdrawQueue(i);
            MarketParams memory marketParams = morpho.idToMarketParams(idMarket);
            uint256 toAdd;
            if (add > 0) {
                toAdd = _calcMarketAdd(IMetaMorpho(vault), idMarket, supplyQueueLength, add);
            }
            // TODO add Jean-Grimal impl which should be ok here https://github.com/Idle-Labs/idle-tranches/pull/87/files
            // as we loop through all withdrawQueue
            uint256 toSub;
            if (sub > 0) {
                toSub = _calcMarketSub(IMetaMorpho(vault), idMarket, queueLength, sub);
            }

            expectedSupply = morpho.expectedSupplyAssets(marketParams, vault);
            if (toSub > 0 && (expectedSupply + toAdd) < toSub) {
                // impossible to remove more than the vault assets
                continue;
            }
            // Use scaled add and sub values to calculate current supply APR Market
            ratio += supplyAPRMarket(marketParams, morpho.market(idMarket), toAdd, toSub).wMulDown(
                // Use scaled add and sub values to calculate assets supplied
                expectedSupply + toAdd - toSub
            );
            // update amount subtracted from vault
            totRemoved += toSub;
        }

        // If there is still some liquidity to remove here it means there is not enough liquidity
        // in the vault to cover the requested withdraw amount
        if (sub - totRemoved > 0) {
            return 0;
        }

        avgSupplyRate = ratio.mulDivDown(WAD - IMetaMorpho(vault).fee(), newTotalAmount);
    }

    /// @notice calculate how much of vault `_add` amount will be added to this market
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
