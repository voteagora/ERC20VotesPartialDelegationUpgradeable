// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {DeployL2GovToken} from "./DeployL2GovToken.s.sol";
import {PartialDelegation} from "src/IVotesPartialDelegation.sol";

contract DeployAndMintToAdminAndTesters is DeployL2GovToken {
  function setUp() public virtual override {
    super.setUp();
  }

  function run() public virtual override {
    super.run();
    vm.startBroadcast(tokenAdmin);
    proxy.grantRole(proxy.MINTER_ROLE(), tokenAdmin);
    // Minting to admin and testing mnemonic accounts
    mintToAdminAndTesters();
    // Delegating to testing mnemonic accounts
    delegateToTesters();
    vm.stopBroadcast();
  }

  function mintToAdminAndTesters() public {
    address[] memory testers = new address[](5);
    testers[0] = 0x5b9c45Ef995Fe31E1C6cb58Dbeb7cb874EF6B060;
    testers[1] = 0x3664eBffA59d4e2Bb89489ec8FB60C91607fe50d;
    testers[2] = 0x68200BA64c6158e890703aa2DF661a957f8f0aA9;
    testers[3] = 0x4D5124802eE0C8782b3092E8d2D058caD345b290;
    testers[4] = 0xa6B883a217D343585DC8f436d277Eae917B77f95;

    proxy.mint(tokenAdmin, 1_000_000 ether);
    console.log("Token admin token balance:\t", proxy.balanceOf(tokenAdmin));
    for (uint256 i = 0; i < testers.length; i++) {
      proxy.mint(testers[i], 100_000 ether);
      console.log("Tester: ", testers[i], "\tToken balance: ", proxy.balanceOf(testers[i]));
    }
  }

  function delegateToTesters() public {
    PartialDelegation[] memory delegates = new PartialDelegation[](5);
    delegates[0] = PartialDelegation(0x3664eBffA59d4e2Bb89489ec8FB60C91607fe50d, 1000);
    delegates[1] = PartialDelegation(0x4D5124802eE0C8782b3092E8d2D058caD345b290, 3000);
    delegates[2] = PartialDelegation(0x5b9c45Ef995Fe31E1C6cb58Dbeb7cb874EF6B060, 2000);
    delegates[3] = PartialDelegation(0x68200BA64c6158e890703aa2DF661a957f8f0aA9, 1500);
    delegates[4] = PartialDelegation(0xa6B883a217D343585DC8f436d277Eae917B77f95, 2500);
    proxy.delegate(delegates);
  }
}
