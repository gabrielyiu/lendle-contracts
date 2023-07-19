// SPDX-License-Identifier: MIT

pragma solidity 0.7.6;

import {IPriceOracle} from '../../interfaces/IPriceOracle.sol';
import '../../interfaces/IPriceFeed.sol';

contract MockPriceFeed is IPriceFeed {
    IPriceOracle private oracle;
    address private asset;

    constructor(IPriceOracle _oracle, address _asset) public {
        oracle = _oracle;
        asset = _asset;
    }

    function fetchPrice() external view override returns (uint256) {
        return oracle.getAssetPrice(asset);
    }

    function updatePrice() external override returns (uint256) {
        return oracle.getAssetPrice(asset);
    }
}
