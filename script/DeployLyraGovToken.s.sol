// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {Vm} from "forge-std/Vm.sol";
import {LyraGovToken} from "src/LyraGovToken.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract DeployLyraGovToken is Script {
  Vm.Wallet deployer;
  address admin;

  function setUp() public {
    uint256 deployerPrivateKey = vm.envOr("DEPLOYER_PK", uint256(12));
    deployer = vm.createWallet(deployerPrivateKey);
    admin = vm.envOr("ADMIN", deployer.addr);
  }

  function run() public {
    vm.broadcast(deployer.privateKey);
    LyraGovToken token = new LyraGovToken();
    console.log(msg.sender);
    console.log(address(this));
    console.log("LyraGovToken impl deployed at: ", address(token));
    ERC1967Proxy proxy = new ERC1967Proxy(address(token), abi.encodeWithSelector(token.initialize.selector, msg.sender));
    console.log("LyraGovToken proxy deployed at: ", address(proxy));
  }
}
