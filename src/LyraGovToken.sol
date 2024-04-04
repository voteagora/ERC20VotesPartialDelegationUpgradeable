// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from
  "./../lib/openzeppelin-contracts-upgradeable/contracts/access/AccessControlUpgradeable.sol";
import {AccessControlDefaultAdminRulesUpgradeable} from
  "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlDefaultAdminRulesUpgradeable.sol";
import {ERC20VotesPartialDelegationUpgradeable} from "src/ERC20VotesPartialDelegationUpgradeable.sol";

contract LyraGovToken is
  UUPSUpgradeable,
  AccessControlUpgradeable,
  // AccessControlDefaultAdminRulesUpgradeable,
  ERC20VotesPartialDelegationUpgradeable
{
  bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
  bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor() {
    _disableInitializers();
  }

  function initialize(address _admin) public initializer {
    __ERC20_init("Lyra Gov Token", "LYRA");
    __AccessControl_init();
    if (_admin == address(0)) {
      revert("Admin cannot be the zero address");
    }
    _grantRole(DEFAULT_ADMIN_ROLE, _admin);
  }

  function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

  function mint(address _account, uint256 _amount) public onlyRole(MINTER_ROLE) {
    _mint(_account, _amount);
  }

  function burn(address _account, uint256 _value) public onlyRole(BURNER_ROLE) {
    _burn(_account, _value);
  }
}
