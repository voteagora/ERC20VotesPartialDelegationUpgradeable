// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20VotesUpgradeable} from
  "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20VotesUpgradeable.sol";

contract LyraGovToken is ERC20VotesUpgradeable {
  function initialize() public initializer {
    __ERC20_init("Lyra Gov Token", "LYRA");
  }
}
