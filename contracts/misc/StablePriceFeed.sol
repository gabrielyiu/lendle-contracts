// SPDX-License-Identifier: MIT

pragma solidity 0.7.6;

import '../interfaces/IPriceFeed.sol';
import '../dependencies/openzeppelin/contracts/SafeMath.sol';

contract StablePriceFeed is IPriceFeed {
  using SafeMath for uint256;

  // Use to convert a price answer to an 18-digit precision uint
  uint256 public constant TARGET_DIGITS = 18;

  function fetchPrice() public view override returns (uint256) {
    return 10**TARGET_DIGITS;
  }

  function updatePrice() external override returns (uint256) {
    return fetchPrice();
  }
}
