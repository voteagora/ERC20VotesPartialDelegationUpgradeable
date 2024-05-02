// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {L2GovToken} from "../src/L2GovToken.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract L2GovTest is Test {
  L2GovToken public tokenImpl;
  L2GovToken public tokenProxy;

  function setUp() public {
    tokenImpl = new L2GovToken();
    tokenProxy = L2GovToken(address(new ERC1967Proxy(address(tokenImpl), "")));
  }
}

contract Initialize is L2GovTest {
  function testInitialize(address _admin) public {
    vm.assume(_admin != address(0));
    assertEq(tokenProxy.name(), "");
    assertEq(tokenProxy.symbol(), "");
    tokenProxy.initialize(_admin);
    assertEq(tokenProxy.name(), "L2 Governance Token");
    assertEq(tokenProxy.symbol(), "gL2");
  }

  function test_RevertIf_InitializeTwice(address _admin) public {
    vm.assume(_admin != address(0));
    tokenProxy.initialize(_admin);
    vm.expectRevert(Initializable.InvalidInitialization.selector);
    tokenProxy.initialize(_admin);
  }
}
