// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {LyraGovToken} from "../src/LyraGovToken.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract LyraGovTest is Test {
  LyraGovToken public tokenImpl;
  LyraGovToken public tokenProxy;

  function setUp() public {
    tokenImpl = new LyraGovToken();
    tokenProxy = LyraGovToken(address(new ERC1967Proxy(address(tokenImpl), "")));
  }
}

contract Initialize is LyraGovTest {
  function testInitialize(address _admin) public {
    vm.assume(_admin != address(0));
    assertEq(tokenProxy.name(), "");
    assertEq(tokenProxy.symbol(), "");
    tokenProxy.initialize(_admin);
    assertEq(tokenProxy.name(), "Lyra Gov Token");
    assertEq(tokenProxy.symbol(), "LYRA");
  }

  function test_RevertIf_InitializeTwice(address _admin) public {
    vm.assume(_admin != address(0));
    tokenProxy.initialize(_admin);
    vm.expectRevert(Initializable.InvalidInitialization.selector);
    tokenProxy.initialize(_admin);
  }
}
