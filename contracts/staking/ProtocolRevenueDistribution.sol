// SPDX-License-Identifier: MIT

pragma solidity 0.7.6;

import '../misc/OwnableUpgradable.sol';

contract ProtocolRevenueDistribution is OwnableUpgradable {
  uint256 public constant VERSION = 0x1;

  /* ========== INITIALIZER ========== */

  function initialize(address owner) external initializer {
    _transferOwnership(owner);
  }
}
