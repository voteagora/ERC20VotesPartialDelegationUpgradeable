// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ERC20VotesPartialDelegationUpgradeable} from "src/ERC20VotesPartialDelegationUpgradeable.sol";

contract FakeERC20VotesPartialDelegationUpgradeable is UUPSUpgradeable, ERC20VotesPartialDelegationUpgradeable {
  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor() {
    _disableInitializers();
  }

  function initialize() public initializer {
    __ERC20_init("Fake Token", "FAKE");
  }

  function _authorizeUpgrade(address) internal override {}

  function mint(uint256 _amount) public {
    _mint(msg.sender, _amount);
  }
}
