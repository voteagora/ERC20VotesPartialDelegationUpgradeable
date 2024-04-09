// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {DeployLyraGovToken} from "./DeployLyraGovToken.s.sol";

contract DeployAndMintToAdmin is DeployLyraGovToken {
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
    console.log("gLYRA admin balance: ", proxy.balanceOf(admin));
  }
}
