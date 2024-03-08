// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {LyraGovToken} from "../src/LyraGovToken.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

contract LyraGovTest is Test {
  LyraGovToken public token;

  function setUp() public {
    token = new LyraGovToken();
  }
}

contract Initialize is LyraGovTest {
  function testInitialize() public {
    assertEq(token.name(), "");
    assertEq(token.symbol(), "");
    token.initialize();
    assertEq(token.name(), "Lyra Gov Token");
    assertEq(token.symbol(), "LYRA");
  }

  function test_RevertIf_InitializeTwice() public {
    token.initialize();
    vm.expectRevert(Initializable.InvalidInitialization.selector);
    token.initialize();
  }
}
