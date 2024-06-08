// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {Vm} from "forge-std/Vm.sol";
import {L2GovToken} from "src/L2GovToken.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

contract DeployL2GovToken is Script {
  address deployer;
  address proxyAdmin;
  address tokenAdmin;
  L2GovToken proxy;

  function setUp() public virtual {
    deployer = vm.envAddress("DEPLOYER_ADDRESS");
    console.log("Deployer address:\t", deployer);
    proxyAdmin = vm.envAddress("PROXY_ADMIN_ADDRESS");
    console.log("Proxy admin address:\t", proxyAdmin);
    tokenAdmin = vm.envAddress("TOKEN_ADMIN_ADDRESS");
    console.log("Token admin address:\t", tokenAdmin);
  }

  function run() public virtual {
    vm.startBroadcast(deployer);
    L2GovToken token = new L2GovToken();
    console.log("L2GovToken impl:\t", address(token));
    proxy = L2GovToken(
      address(
        new TransparentUpgradeableProxy(
          address(token), proxyAdmin, abi.encodeWithSelector(token.initialize.selector, tokenAdmin)
        )
      )
    );
    console.log("L2GovToken proxy:\t", address(proxy));
    vm.stopBroadcast();
  }
}
