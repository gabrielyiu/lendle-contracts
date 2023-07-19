pragma solidity 0.7.6;

interface IMultiFeeDistribution {
  event Paused();
  event Unpaused();

  function addReward(address rewardsToken) external;

  function mint(
    address user,
    uint256 amount,
    bool withPenalty
  ) external;
}
