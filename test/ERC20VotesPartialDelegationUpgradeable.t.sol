// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {FakeERC20VotesPartialDelegationUpgradeable} from "./fakes/FakeERC20VotesPartialDelegationUpgradeable.sol";
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
    assertEq(a.length, b.length, "length mismatch");
    for (uint256 i = 0; i < a.length; i++) {
      assertEq(a[i]._delegatee, b[i]._delegatee, "delegatee mismatch");
      assertEq(a[i]._numerator, b[i]._numerator, "numerator mismatch");
    }
  }

  function _createValidPartialDelegation(uint256 _n, uint256 _seed) internal view returns (PartialDelegation[] memory) {
    _seed = bound(
      _seed,
      1,
      /* private key can't be bigger than secp256k1 curve order */
      115_792_089_237_316_195_423_570_985_008_687_907_852_837_564_279_074_904_382_605_163_141_518_161_494_337 - 1
    );
    _n = _n != 0 ? _n : (_seed % tokenProxy.MAX_PARTIAL_DELEGATIONS()) + 1;
    PartialDelegation[] memory delegations = new PartialDelegation[](_n);
    uint96 _totalNumerator;
    for (uint256 i = 0; i < _n; i++) {
      // TODO: determine if this numerator definition is correct (I think it's selecting `1` every time)
      console.log(
        _n,
        i,
        uint256(keccak256(abi.encode(_seed + i))) % tokenProxy.DENOMINATOR(),
        tokenProxy.DENOMINATOR() - _totalNumerator - (_n - i)
      );
      uint96 _numerator = uint96(
        bound(
          uint256(keccak256(abi.encode(_seed + i))) % tokenProxy.DENOMINATOR(),
          1,
          tokenProxy.DENOMINATOR() - _totalNumerator - (_n - i)
        )
      );
      delegations[i] = PartialDelegation(address(uint160(uint160(vm.addr(_seed)) + i)), _numerator);
      _totalNumerator += _numerator;
    }
    return delegations;
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

  function testFuzz_DelegatesToAnySingleAddress(address _actor, address _delegatee, uint256 _amount) public {
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

  function testFuzz_DelegatesToZeroAddress(address _actor, uint256 _amount) public {
    vm.assume(_actor != address(0));
    _amount = bound(_amount, 0, type(uint208).max);
    vm.startPrank(_actor);
    tokenProxy.mint(_amount);
    PartialDelegation[] memory delegations = new PartialDelegation[](1);
    delegations[0] = PartialDelegation(address(0), 1);
    tokenProxy.delegate(delegations);
    vm.stopPrank();
    assertEq(tokenProxy.delegates(_actor), delegations);
    assertEq(tokenProxy.balanceOf(_actor), _amount);
  }

  function testFuzz_DelegatesToTwoAddressesWithCorrectNumeratorSum(
    address _actor,
    address _delegatee1,
    address _delegatee2,
    uint256 _amount,
    uint96 _numerator1,
    uint96 _numerator2
  ) public {
    vm.assume(_actor != address(0));
    vm.assume(_delegatee1 != address(0));
    vm.assume(_delegatee2 != address(0));
    vm.assume(_delegatee1 < _delegatee2);
    _amount = bound(_amount, 0, type(uint208).max);
    _numerator1 = uint96(bound(_numerator1, 1, tokenProxy.DENOMINATOR() - 1));
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

  function testFuzz_DelegatesToTwoAddressesWithNumeratorsSummingToLessThan100(
    address _actor,
    address _delegatee1,
    address _delegatee2,
    uint256 _amount,
    uint96 _numerator1,
    uint96 _numerator2
  ) public {
    vm.assume(_actor != address(0));
    vm.assume(_delegatee1 != address(0));
    vm.assume(_delegatee2 != address(0));
    vm.assume(_delegatee1 < _delegatee2);
    _amount = bound(_amount, 0, type(uint208).max);
    _numerator1 = uint96(bound(_numerator1, 1, tokenProxy.DENOMINATOR() - 2));
    // numerator1 + numerator2 < 100
    _numerator2 = uint96(bound(_numerator2, 1, tokenProxy.DENOMINATOR() - _numerator1 - 1));
    vm.startPrank(_actor);
    tokenProxy.mint(_amount);
    PartialDelegation[] memory delegations = new PartialDelegation[](2);
    delegations[0] = PartialDelegation(_delegatee1, _numerator1);
    delegations[1] = PartialDelegation(_delegatee2, _numerator2);
    tokenProxy.delegate(delegations);
    vm.stopPrank();
    assertEq(tokenProxy.delegates(_actor), delegations);
    assertEq(tokenProxy.getVotes(_delegatee1), _amount * _numerator1 / tokenProxy.DENOMINATOR());
    assertEq(tokenProxy.getVotes(_delegatee2), _amount - tokenProxy.getVotes(_delegatee1));
    assertApproxEqAbs(
      tokenProxy.getVotes(_delegatee2), _amount * (tokenProxy.DENOMINATOR() - _numerator1) / tokenProxy.DENOMINATOR(), 1
    );
    assertEq(tokenProxy.getVotes(_delegatee1) + tokenProxy.getVotes(_delegatee2), _amount);
    assertEq(tokenProxy.balanceOf(_actor), _amount);
  }

  function testFuzz_DelegatesToNAddressesWithCorrectNumeratorSum(
    address _actor,
    uint256 _amount,
    uint256 _n,
    uint256 _seed
  ) public {
    vm.assume(_actor != address(0));
    _amount = bound(_amount, 0, type(uint208).max);
    _n = bound(_n, 1, tokenProxy.MAX_PARTIAL_DELEGATIONS());
    PartialDelegation[] memory delegations = _createValidPartialDelegation(_n, _seed);
    vm.startPrank(_actor);
    tokenProxy.mint(_amount);
    tokenProxy.delegate(delegations);
    vm.stopPrank();
    assertEq(tokenProxy.delegates(_actor), delegations);
    uint256 _totalVotes = 0;
    for (uint256 i = 0; i < _n; i++) {
      if (i == _n - 1) {
        assertEq(
          tokenProxy.getVotes(delegations[i]._delegatee), _amount - _totalVotes, "last voter has wrong vote amount"
        );
      } else {
        assertEq(
          tokenProxy.getVotes(delegations[i]._delegatee),
          _amount * delegations[i]._numerator / tokenProxy.DENOMINATOR(),
          "voter has wrong vote amount"
        );
      }
      _totalVotes += tokenProxy.getVotes(delegations[i]._delegatee);
    }
    assertEq(_totalVotes, _amount, "totalVotes mismatch");
  }

  function testFuzz_DelegatesToNAddressesAndThenDelegatesToOtherAddresses(
    address _actor,
    uint256 _amount,
    uint256 _n,
    uint256 _seed
  ) public {
    vm.assume(_actor != address(0));
    _amount = bound(_amount, 0, type(uint208).max);
    _n = bound(_n, 1, tokenProxy.MAX_PARTIAL_DELEGATIONS());
    PartialDelegation[] memory delegations = _createValidPartialDelegation(_n, _seed);
    vm.startPrank(_actor);
    tokenProxy.mint(_amount);
    tokenProxy.delegate(delegations);
    vm.stopPrank();
    assertEq(tokenProxy.delegates(_actor), delegations);
    PartialDelegation[] memory newDelegations = _createValidPartialDelegation( /* setting n to 0 here means seed will
      generate random n */ 0, uint256(keccak256(abi.encode(_seed))));
    vm.startPrank(_actor);
    tokenProxy.delegate(newDelegations);
    vm.stopPrank();
    assertEq(tokenProxy.delegates(_actor), newDelegations);
    uint256 _totalVotes = 0;
    _n = newDelegations.length;
    for (uint256 i = 0; i < _n; i++) {
      if (i == _n - 1) {
        console.log("last voter...");
        assertEq(
          tokenProxy.getVotes(newDelegations[i]._delegatee), _amount - _totalVotes, "last voter has wrong vote amount"
        );
      } else {
        assertEq(
          tokenProxy.getVotes(newDelegations[i]._delegatee),
          _amount * newDelegations[i]._numerator / tokenProxy.DENOMINATOR(),
          "voter has wrong vote amount"
        );
      }
      _totalVotes += tokenProxy.getVotes(newDelegations[i]._delegatee);
    }
    assertEq(_totalVotes, _amount, "totalVotes mismatch");
    // initial delegates should have 0 vote power (assuming set union is empty)
    for (uint256 i = 0; i < delegations.length; i++) {
      assertEq(tokenProxy.getVotes(delegations[i]._delegatee), 0, "initial delegate has vote power");
    }
  }

  function testFuzz_RevertIf_DelegationArrayIncludesDuplicates(
    address _actor,
    address _delegatee,
    uint256 _amount,
    uint96 _numerator
  ) public {
    vm.assume(_actor != address(0));
    vm.assume(_delegatee != address(0));
    _amount = bound(_amount, 0, type(uint208).max);
    _numerator = uint96(bound(_numerator, 1, tokenProxy.DENOMINATOR() - 1));
    vm.startPrank(_actor);
    tokenProxy.mint(_amount);
    PartialDelegation[] memory delegations = new PartialDelegation[](2);
    delegations[0] = PartialDelegation(_delegatee, _numerator);
    delegations[1] = PartialDelegation(_delegatee, tokenProxy.DENOMINATOR() - _numerator);
    vm.expectRevert();
    tokenProxy.delegate(delegations);
    vm.stopPrank();
  }

  function testFuzz_RevertIf_DelegationArrayNumeratorsSumToGreaterThanDenominator(
    address _actor,
    address _delegatee1,
    address _delegatee2,
    uint256 _amount,
    uint96 _numerator1,
    uint96 _numerator2
  ) public {
    vm.assume(_actor != address(0));
    vm.assume(_delegatee1 != address(0));
    vm.assume(_delegatee2 != address(0));
    vm.assume(_delegatee1 < _delegatee2);
    _amount = bound(_amount, 0, type(uint208).max);
    _numerator1 = uint96(bound(_numerator1, 1, tokenProxy.DENOMINATOR()));
    _numerator2 = uint96(bound(_numerator2, tokenProxy.DENOMINATOR() - _numerator1 + 1, type(uint96).max - _numerator1));
    vm.startPrank(_actor);
    tokenProxy.mint(_amount);
    PartialDelegation[] memory delegations = new PartialDelegation[](2);
    delegations[0] = PartialDelegation(_delegatee1, _numerator1);
    delegations[1] = PartialDelegation(_delegatee2, _numerator2);
    vm.expectRevert();
    tokenProxy.delegate(delegations);
    vm.stopPrank();
  }

  function testFuzz_RevertIf_DelegationNumeratorTooLarge(
    address _actor,
    address _delegatee,
    uint256 _amount,
    uint96 _numerator
  ) public {
    vm.assume(_actor != address(0));
    vm.assume(_delegatee != address(0));
    _numerator = uint96(bound(_numerator, tokenProxy.DENOMINATOR() + 1, type(uint96).max));
    _amount = bound(_amount, 0, type(uint208).max);
    vm.startPrank(_actor);
    tokenProxy.mint(_amount);
    PartialDelegation[] memory delegations = new PartialDelegation[](1);
    delegations[0] = PartialDelegation(_delegatee, _numerator);
    vm.expectRevert();
    tokenProxy.delegate(delegations);
    vm.stopPrank();
  }
}

contract DelegateBySig is PartialDelegationTest {}

contract Transfer is PartialDelegationTest {
  function testFuzz_MovesVotesFromOneDelegateeSetToAnother(
    address _from,
    address _to,
    uint256 _amount,
    uint256 _toExistingBalance
  ) public {
    vm.assume(_from != address(0));
    vm.assume(_to != address(0));
    vm.assume(_from != _to);
    _amount = bound(_amount, 0, type(uint208).max);
    _toExistingBalance = bound(_toExistingBalance, 0, type(uint208).max - _amount);
    PartialDelegation[] memory _fromDelegations =
      _createValidPartialDelegation(0, uint256(keccak256(abi.encode(_from))));
    PartialDelegation[] memory _toDelegations = _createValidPartialDelegation(0, uint256(keccak256(abi.encode(_to))));
    vm.startPrank(_to);
    tokenProxy.mint(_toExistingBalance);
    tokenProxy.delegate(_toDelegations);
    vm.stopPrank();
    vm.startPrank(_from);
    tokenProxy.mint(_amount);
    tokenProxy.delegate(_fromDelegations);
    tokenProxy.transfer(_to, _amount);
    vm.stopPrank();

    // check that voting power has been reduced on `from` side by proper amount
    uint256 _fromTotal = 0;
    for (uint256 i = 0; i < _fromDelegations.length; i++) {
      assertEq(tokenProxy.getVotes(_fromDelegations[i]._delegatee), 0);
      _fromTotal += tokenProxy.getVotes(_fromDelegations[i]._delegatee);
    }
    assertEq(_fromTotal, 0, "`from` address total votes mismatch");
    // check that voting power has been augmented on `to` side by proper amount
    uint256 _toTotal = 0;
    for (uint256 i = 0; i < _toDelegations.length; i++) {
      if (i == _toDelegations.length - 1) {
        console.log("last voter...");
        assertEq(
          tokenProxy.getVotes(_toDelegations[i]._delegatee),
          _toExistingBalance + _amount - _toTotal,
          "last voter has wrong vote amount"
        );
      } else {
        assertEq(
          tokenProxy.getVotes(_toDelegations[i]._delegatee),
          (_toExistingBalance + _amount) * _toDelegations[i]._numerator / tokenProxy.DENOMINATOR(),
          "voter has wrong vote amount"
        );
      }
      _toTotal += tokenProxy.getVotes(_toDelegations[i]._delegatee);
    }
    assertEq(_toTotal, _toExistingBalance + _amount, "`to` address total votes mismatch");
    // check that the asset balance successfully updated
    assertEq(tokenProxy.balanceOf(_from), 0, "nonzero `from` balance");
    assertEq(tokenProxy.balanceOf(_to), _toExistingBalance + _amount, "`to` balance mismatch");
    assertEq(tokenProxy.totalSupply(), _toExistingBalance + _amount, "total supply mismatch");
  }

  function testFuzz_CreatesVotesWhenSenderHasNotDelegated() public {
    vm.skip(true);
  }

  function testFuzz_RemovesVotesWhenReceiverHasNotDelegated() public {
    vm.skip(true);
  }

  function testFuzz_HandlesTransfersToSelf(address _holder, uint256 _transferAmount, uint256 _existingBalance) public {
    vm.assume(_holder != address(0));
    _transferAmount = bound(_transferAmount, 0, type(uint208).max);
    _existingBalance = bound(_existingBalance, _transferAmount, type(uint208).max);
    PartialDelegation[] memory _delegations = _createValidPartialDelegation(0, uint256(keccak256(abi.encode(_holder))));
    vm.startPrank(_holder);
    tokenProxy.mint(_existingBalance);
    tokenProxy.delegate(_delegations);
    tokenProxy.transfer(_holder, _transferAmount);
    vm.stopPrank();

    uint256 _total = 0;
    for (uint256 i = 0; i < _delegations.length; i++) {
      if (i == _delegations.length - 1) {
        console.log("last voter...");
        assertEq(
          tokenProxy.getVotes(_delegations[i]._delegatee), _existingBalance - _total, "last voter has wrong vote amount"
        );
      } else {
        assertEq(
          tokenProxy.getVotes(_delegations[i]._delegatee),
          _existingBalance * _delegations[i]._numerator / tokenProxy.DENOMINATOR(),
          "voter has wrong vote amount"
        );
      }
      _total += tokenProxy.getVotes(_delegations[i]._delegatee);
    }
    assertEq(_total, _existingBalance, "vote count is wrong");
    assertEq(tokenProxy.balanceOf(_holder), _existingBalance, "holder balance is wrong");
    assertEq(tokenProxy.totalSupply(), _existingBalance, "total supply mismatch");
  }
}

contract Integration is PartialDelegationTest {
  function testFuzz_DelegateAndTransferAndDelegate(
    address _actor,
    address _delegatee1,
    address _delegatee2,
    uint256 _amount
  ) public {
    vm.skip(true);
  }

  function testFuzz_DelegateAndTransferAndDelegateAndTransfer(
    address _actor,
    address _delegatee1,
    address _delegatee2,
    uint256 _amount
  ) public {
    vm.skip(true);
  }
}
