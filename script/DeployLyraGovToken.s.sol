// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {Vm} from "forge-std/Vm.sol";
import {LyraGovToken} from "src/LyraGovToken.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract DeployLyraGovToken is Script {
  Vm.Wallet deployer;
  address admin;
  LyraGovToken proxy;

  function setUp() public virtual {
    uint256 deployerPrivateKey = vm.envOr("DEPLOYER_PRIVATE_KEY", uint256(12));
    deployer = vm.createWallet(deployerPrivateKey);
    console.log("Deployer address: ", deployer.addr);
    admin = vm.envOr("ADMIN_ADDRESS", deployer.addr);
    console.log("Admin address: ", admin);
  }

  function run() public virtual {
    vm.broadcast(deployer.privateKey);
    LyraGovToken token = new LyraGovToken();
    console.log("LyraGovToken impl deployed at: ", address(token));
    proxy =
      LyraGovToken(address(new ERC1967Proxy(address(token), abi.encodeWithSelector(token.initialize.selector, admin))));
    console.log("LyraGovToken proxy deployed at: ", address(proxy));
  }
}
