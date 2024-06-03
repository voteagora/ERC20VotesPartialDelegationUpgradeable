// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ERC20VotesPartialDelegationUpgradeable} from "src/ERC20VotesPartialDelegationUpgradeable.sol";
import {PartialDelegation, DelegationAdjustment} from "src/IVotesPartialDelegation.sol";

contract FakeERC20VotesPartialDelegationUpgradeable is UUPSUpgradeable, ERC20VotesPartialDelegationUpgradeable {
  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor() {
    _disableInitializers();
  }

  function initialize() public initializer {
    __ERC20_init("Fake Token", "FAKE");
    __EIP712_init("Fake Token", "1");
  }

  function _authorizeUpgrade(address) internal override {}

  function mint(uint256 _amount) public {
    _mint(msg.sender, _amount);
  }

  function exposed_calculateWeightDistribution(PartialDelegation[] memory _partialDelegations, uint256 _amount)
    public
    pure
    returns (DelegationAdjustment[] memory)
  {
    return _calculateWeightDistribution(_partialDelegations, _amount);
  }

  function exposed_calculateWeightDistributionAndRemainder(
    PartialDelegation[] memory _partialDelegations,
    uint256 _amount
  ) public pure returns (DelegationAdjustment[] memory, uint208) {
    DelegationAdjustment[] memory _adjustments = _calculateWeightDistribution(_partialDelegations, _amount);
    uint208 _remainder;
    for (uint256 i = 0; i < _adjustments.length; i++) {
      _remainder += _adjustments[i]._amount;
    }
    return (_adjustments, _remainder);
  }
}
