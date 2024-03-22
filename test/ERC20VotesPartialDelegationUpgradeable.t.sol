// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {FakeERC20VotesPartialDelegationUpgradeable} from "./fakes/FakeERC20VotesPartialDelegationUpgradeable.sol";
import {ERC20VotesPartialDelegationUpgradeable} from "src/ERC20VotesPartialDelegationUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {PartialDelegation} from "src/IVotesPartialDelegation.sol";

contract PartialDelegationTest is Test {
  FakeERC20VotesPartialDelegationUpgradeable public tokenImpl;
  FakeERC20VotesPartialDelegationUpgradeable public tokenProxy;

  function setUp() public {
    tokenImpl = new FakeERC20VotesPartialDelegationUpgradeable();
    tokenProxy = FakeERC20VotesPartialDelegationUpgradeable(address(new ERC1967Proxy(address(tokenImpl), "")));
    tokenProxy.initialize();
  }

  function assertEq(PartialDelegation[] memory a, PartialDelegation[] memory b) public {
    assertEq(a.length, b.length);
    for (uint256 i = 0; i < a.length; i++) {
      assertEq(a[i]._delegatee, b[i]._delegatee);
      assertEq(a[i]._numerator, b[i]._numerator);
    }
  }
}

contract Delegate is PartialDelegationTest {
  function testFuzz_DelegatesToSingleAddressSelf(address _actor, uint256 _amount) public {
    vm.assume(_actor != address(0));
    _amount = bound(_amount, 0, type(uint208).max);
    vm.startPrank(_actor);
    tokenProxy.mint(_amount);
    PartialDelegation[] memory delegations = new PartialDelegation[](1);
    delegations[0] = PartialDelegation(_actor, 1);
    tokenProxy.delegate(delegations);
    vm.stopPrank();
    assertEq(tokenProxy.delegates(_actor), delegations);
    assertEq(tokenProxy.getVotes(_actor), _amount);
  }

  function testFuzz_DelegatesToAnyAddress(address _actor, address _delegatee, uint256 _amount) public {
    vm.assume(_actor != address(0));
    vm.assume(_delegatee != address(0));
    _amount = bound(_amount, 0, type(uint208).max);
    vm.startPrank(_actor);
    tokenProxy.mint(_amount);
    PartialDelegation[] memory delegations = new PartialDelegation[](1);
    delegations[0] = PartialDelegation(_delegatee, 1);
    tokenProxy.delegate(delegations);
    vm.stopPrank();
    assertEq(tokenProxy.delegates(_actor), delegations);
    assertEq(tokenProxy.getVotes(_delegatee), _amount);
  }

  function testFuzz_DelegatesToTwoAddressesWithCorrectNumeratorSum(
    address _actor,
    address _delegatee1,
    address _delegatee2,
    uint256 _amount,
    uint8 _numerator1,
    uint8 _numerator2
  ) public {
    vm.assume(_actor != address(0));
    vm.assume(_delegatee1 != address(0));
    vm.assume(_delegatee2 != address(0));
    vm.assume(_delegatee1 != _delegatee2);
    _amount = bound(_amount, 0, type(uint208).max);
    // TODO: should we support delegations w 0 numerator?
    _numerator1 = uint8(bound(_numerator1, 1, tokenProxy.DENOMINATOR() - 1));
    _numerator2 = tokenProxy.DENOMINATOR() - _numerator1;
    vm.startPrank(_actor);
    tokenProxy.mint(_amount);
    PartialDelegation[] memory delegations = new PartialDelegation[](2);
    delegations[0] = PartialDelegation(_delegatee1, _numerator1);
    delegations[1] = PartialDelegation(_delegatee2, _numerator2);
    tokenProxy.delegate(delegations);
    vm.stopPrank();
    assertEq(tokenProxy.delegates(_actor), delegations);
    assertEq(tokenProxy.getVotes(_delegatee1), _amount * _numerator1 / tokenProxy.DENOMINATOR());
    uint256 _expectedLastDelegateeWeight = _amount - tokenProxy.getVotes(_delegatee1);
    assertEq(tokenProxy.getVotes(_delegatee2), _expectedLastDelegateeWeight);
    assertApproxEqAbs(tokenProxy.getVotes(_delegatee2), _amount * _numerator2 / tokenProxy.DENOMINATOR(), 1);
    assertEq(tokenProxy.getVotes(_delegatee1) + tokenProxy.getVotes(_delegatee2), _amount);
  }

  // TODO: include this test if we change to a different type/denominator pair for _numerator
  // function testFuzz_RevertIf_DelegationNumeratorTooLarge(
  //   address _actor,
  //   address _delegatee,
  //   uint256 _amount,
  //   uint8 _numerator
  // ) public {
  //   vm.assume(_actor != address(0));
  //   vm.assume(_delegatee != address(0));
  //   _numerator = uint8(bound(_numerator, tokenProxy.DENOMINATOR() + 1, type(uint8).max));
  //   _amount = bound(_amount, 0, type(uint208).max);
  //   vm.startPrank(_actor);
  //   tokenProxy.mint(_amount);
  //   PartialDelegation[] memory delegations = new PartialDelegation[](1);
  //   delegations[0] = PartialDelegation(_delegatee, _numerator);
  //   vm.expectRevert();
  //   tokenProxy.delegate(delegations);
  //   vm.stopPrank();
  // }
}
