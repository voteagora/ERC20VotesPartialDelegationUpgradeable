// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {DeployL2GovToken} from "./DeployL2GovToken.s.sol";

contract DeployAndMintToAdminAndTesters is DeployL2GovToken {
  function setUp() public virtual override {
    super.setUp();
    admin = deployer.addr;
  }

  function run() public virtual override {
    super.run();
    vm.startBroadcast(deployer.privateKey);
    proxy.grantRole(proxy.MINTER_ROLE(), admin);
    // Minting to admin and testing mnemonic accounts
    mintToAdminAndTesters();
    vm.stopBroadcast();
  }

  function mintToAdminAndTesters() public {
    address[] memory testers = new address[](5);
    testers[0] = 0x5b9c45Ef995Fe31E1C6cb58Dbeb7cb874EF6B060;
    testers[1] = 0x3664eBffA59d4e2Bb89489ec8FB60C91607fe50d;
    testers[2] = 0x68200BA64c6158e890703aa2DF661a957f8f0aA9;
    testers[3] = 0x4D5124802eE0C8782b3092E8d2D058caD345b290;
    testers[4] = 0xa6B883a217D343585DC8f436d277Eae917B77f95;

    proxy.mint(admin, 1_000_000 ether);
    console.log("Admin token balance:\t", proxy.balanceOf(admin));
    for (uint256 i = 0; i < testers.length; i++) {
      proxy.mint(testers[i], 100_000 ether);
      console.log("Tester: ", testers[i], "\tToken balance: ", proxy.balanceOf(testers[i]));
    }
  }
}
