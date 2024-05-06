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
    __EIP712_init("Fake Token", "1");
  }

  function _authorizeUpgrade(address) internal override {}

  function mint(uint256 _amount) public {
    _mint(msg.sender, _amount);
  }
}

/// @notice Interface of the ERC1271 standard signature validation method for contracts as defined
/// in https://eips.ethereum.org/EIPS/eip-1271[ERC-1271].
interface IERC1271 {
  /// @notice Should return whether the signature provided is valid for the provided data
  /// @param hash Hash of the data to be signed
  /// @param signature Signature byte array associated with _data
  function isValidSignature(bytes32 hash, bytes memory signature) external view returns (bytes4 magicValue);
}
