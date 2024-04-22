// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {DeployL2GovToken} from "./DeployL2GovToken.s.sol";

contract DeployAndMintToAdmin is DeployL2GovToken {
  function setUp() public virtual override {
    super.setUp();
    admin = deployer.addr;
  }

  function run() public virtual override {
    super.run();
    vm.startBroadcast(deployer.privateKey);
    proxy.grantRole(proxy.MINTER_ROLE(), admin);
    proxy.mint(admin, type(uint208).max);
    vm.stopBroadcast();
    console.log("L2GovToken admin balance:\t", proxy.balanceOf(admin));
  }
}
