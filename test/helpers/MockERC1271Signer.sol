// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";

contract MockERC1271Signer is IERC1271 {
  bytes4 public constant MAGICVALUE = 0x1626ba7e;
  bytes4 public response__isValidSignature;

  function setResponse__isValidSignature(bool _nextResponse) external {
    if (_nextResponse) {
      // If the mock should signal the signature is valid, it should return the MAGICVALUE
      response__isValidSignature = MAGICVALUE;
    } else {
      // If the mock should signal it is not valid, we'll return an arbitrary four bytes derived
      // from the address where the mock happens to be deployed
      response__isValidSignature = bytes4(keccak256(abi.encode(address(this))));
    }
  }

  function isValidSignature(bytes32, /* hash */ bytes memory /* signature */ )
    external
    view
    returns (bytes4 magicValue)
  {
    magicValue = response__isValidSignature;
  }
}
