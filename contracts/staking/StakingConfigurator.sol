// SPDX-License-Identifier: agpl-3.0
pragma solidity 0.7.6;
pragma experimental ABIEncoderV2;

import {VersionedInitializable} from '../protocol/libraries/aave-upgradeability/VersionedInitializable.sol';
import {InitializableImmutableAdminUpgradeabilityProxy} from '../protocol/libraries/aave-upgradeability/InitializableImmutableAdminUpgradeabilityProxy.sol';
import {ILendingPoolAddressesProvider} from '../interfaces/ILendingPoolAddressesProvider.sol';
import {Errors} from '../protocol/libraries/helpers/Errors.sol';

contract StakingConfigurator is VersionedInitializable {
  event ProxyCreated(bytes32 id, address indexed newAddress);
  event MultiFeeDistributionUpdated(address indexed newAddress);
  event ChefIncentivesControllerUpdated(address indexed newAddress);
  event MasterChefUpdated(address indexed newAddress);
  event ProtocolRevenueDistributionUpdated(address indexed newAddress);

  ILendingPoolAddressesProvider internal addressesProvider;
  mapping(bytes32 => address) private _addresses;

  bytes32 private constant CHEF_INCENTIVES_CONTROLLER = 'CHEF_INCENTIVES_CONTROLLER';
  bytes32 private constant MASTER_CHEF = 'MASTER_CHEF';
  bytes32 private constant MULTI_FEE_DISTRIBUTION = 'MULTI_FEE_DISTRIBUTION';
  bytes32 private constant PROTOCOL_REVENUE_DISTRIBUTION = 'PROTOCOL_REVENUE_DISTRIBUTION';

  modifier onlyPoolAdmin {
    require(addressesProvider.getPoolAdmin() == msg.sender, Errors.CALLER_NOT_POOL_ADMIN);
    _;
  }
  
  uint256 internal constant CONFIGURATOR_REVISION = 0x1;

  function getRevision() internal pure override returns (uint256) {
    return CONFIGURATOR_REVISION;
  }

  function initialize(ILendingPoolAddressesProvider provider) public initializer {
    addressesProvider = provider;
  }

  /**
   * @dev Returns an address by id
   * @return The address
   */
  function getAddress(bytes32 id) public view returns (address) {
    return _addresses[id];
  }

  function getMultiFeeDistribution() external view returns (address) {
    return getAddress(MULTI_FEE_DISTRIBUTION);
  }

  function setMultiFeeDistributionImpl(address impl, bytes calldata initParams) external onlyPoolAdmin {
    _updateImpl(MULTI_FEE_DISTRIBUTION, impl, initParams);
    emit MultiFeeDistributionUpdated(impl);
  }

  function getChefIncentivesController() external view returns (address) {
    return getAddress(CHEF_INCENTIVES_CONTROLLER);
  }

  function setChefIncentivesControllerImpl(address impl, bytes calldata initParams) external onlyPoolAdmin {
    _updateImpl(CHEF_INCENTIVES_CONTROLLER, impl, initParams);
    emit ChefIncentivesControllerUpdated(impl);
  }

  function getMasterChef() external view returns (address) {
    return getAddress(MASTER_CHEF);
  }

  function setMasterChefImpl(address impl, bytes calldata initParams) external onlyPoolAdmin {
    _updateImpl(MASTER_CHEF, impl, initParams);
    emit MasterChefUpdated(impl);
  }

  function getProtocolRevenueDistribution() external view returns (address) {
    return getAddress(PROTOCOL_REVENUE_DISTRIBUTION);
  }

  function setProtocolRevenueDistributionImpl(address impl, bytes calldata initParams) external onlyPoolAdmin {
    _updateImpl(PROTOCOL_REVENUE_DISTRIBUTION, impl, initParams);
    emit ProtocolRevenueDistributionUpdated(impl);
  }

  /**
   * @dev Internal function to update the implementation of a specific proxied component of the protocol
   * - If there is no proxy registered in the given `id`, it creates the proxy setting `newAdress`
   *   as implementation and calls the initialize() function on the proxy
   * - If there is already a proxy registered, it just updates the implementation to `newAddress` and
   *   calls the initialize() function via upgradeToAndCall() in the proxy
   * @param id The id of the proxy to be updated
   * @param newAddress The address of the new implementation
   **/
  function _updateImpl(bytes32 id, address newAddress, bytes memory initParams) internal {
    address payable proxyAddress = payable(_addresses[id]);

    InitializableImmutableAdminUpgradeabilityProxy proxy =
      InitializableImmutableAdminUpgradeabilityProxy(proxyAddress);

    if (proxyAddress == address(0)) {
      proxy = new InitializableImmutableAdminUpgradeabilityProxy(address(this));
      proxy.initialize(newAddress, initParams);
      _addresses[id] = address(proxy);
      emit ProxyCreated(id, address(proxy));
    } else {
      if(initParams.length > 0) {
        proxy.upgradeToAndCall(newAddress, initParams);
      } else {
        proxy.upgradeTo(newAddress);
      }
    }
  }
}
