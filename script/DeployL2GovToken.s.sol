// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {Vm} from "forge-std/Vm.sol";
import {L2GovToken} from "src/L2GovToken.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract DeployL2GovToken is Script {
  Vm.Wallet deployer;
  address admin;
  L2GovToken proxy;

  function setUp() public virtual {
    uint256 deployerPrivateKey = vm.envOr("DEPLOYER_PRIVATE_KEY", uint256(12));
    deployer = vm.createWallet(deployerPrivateKey);
    console.log("Deployer address:\t", deployer.addr);
    admin = vm.envOr("ADMIN_ADDRESS", deployer.addr);
    console.log("Admin address:\t", admin);
  }

  function run() public virtual {
    vm.startBroadcast(deployer.privateKey);
    L2GovToken token = new L2GovToken();
    console.log("L2GovToken impl:\t", address(token));
    proxy =
      L2GovToken(address(new ERC1967Proxy(address(token), abi.encodeWithSelector(token.initialize.selector, admin))));
    console.log("L2GovToken proxy:\t", address(proxy));
    vm.stopBroadcast();
  }
}
