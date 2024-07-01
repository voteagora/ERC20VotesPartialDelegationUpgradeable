// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {console, StdStorage, stdStorage, Vm} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {DelegationAndEventHelpers} from "test/helpers/DelegationAndEventHelpers.sol";
import {FakeERC20VotesPartialDelegationUpgradeable} from "test/fakes/FakeERC20VotesPartialDelegationUpgradeable.sol";
import {MockERC1271Signer} from "test/helpers/MockERC1271Signer.sol";
import {PartialDelegation, DelegationAdjustment} from "src/IVotesPartialDelegation.sol";

contract PartialDelegationTest is DelegationAndEventHelpers {
  /// @notice An invalid signature is provided.
  error InvalidSignature();
  /// @dev The nonce used for an `account` is not the expected current nonce.
  error InvalidAccountNonce(address account, uint256 currentNonce);
  /// @dev The signature used has expired.
  error VotesExpiredSignature(uint256 expiry);
  /// @notice Emitted when the number of delegatees exceeds the limit.
  error PartialDelegationLimitExceeded(uint256 length, uint256 max);
  /// @notice Emitted when the provided delegatee list is not sorted or contains duplicates.
  error DuplicateOrUnsortedDelegatees(address delegatee);
  /// @notice Emitted when the provided numerator is zero.
  error InvalidNumeratorZero();
  /// @notice Emitted when the sum of the numerators exceeds the denominator.
  error NumeratorSumExceedsDenominator(uint256 numerator, uint96 denominator);

  FakeERC20VotesPartialDelegationUpgradeable public tokenImpl;
  FakeERC20VotesPartialDelegationUpgradeable public tokenProxy;
  bytes32 DOMAIN_SEPARATOR;

  function setUp() public virtual {
    tokenImpl = new FakeERC20VotesPartialDelegationUpgradeable();
    tokenProxy = FakeERC20VotesPartialDelegationUpgradeable(address(new ERC1967Proxy(address(tokenImpl), "")));
    tokenProxy.initialize();
    DelegationAndEventHelpers.initialize(address(tokenProxy));
    // TODO: try to build this with contract state rather than fixed values
    DOMAIN_SEPARATOR = keccak256(
      abi.encode(
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
        keccak256("Fake Token"),
        keccak256("1"),
        block.chainid,
        address(tokenProxy)
      )
    );
  }

  function assertEq(PartialDelegation[] memory a, PartialDelegation[] memory b) public {
    assertEq(a.length, b.length, "length mismatch");
    for (uint256 i = 0; i < a.length; i++) {
      assertEq(a[i]._delegatee, b[i]._delegatee, "delegatee mismatch");
      assertEq(a[i]._numerator, b[i]._numerator, "numerator mismatch");
    }
  }

  function assertCorrectVotes(PartialDelegation[] memory _delegations, uint256 _amount) internal {
    DelegationAdjustment[] memory _votes = tokenProxy.exposed_calculateWeightDistribution(_delegations, _amount);
    uint256 _totalWeight = 0;
    for (uint256 i = 0; i < _delegations.length; i++) {
      uint256 _expectedVoteWeight = _delegations[i]._delegatee == address(0) ? 0 : _votes[i]._amount;
      assertEq(
        tokenProxy.getVotes(_delegations[i]._delegatee), _expectedVoteWeight, "incorrect vote weight for delegate"
      );
      _totalWeight += _votes[i]._amount;
    }
    assertLe(_totalWeight, _amount, "incorrect total weight");
  }

  function assertCorrectPastVotes(PartialDelegation[] memory _delegations, uint256 _amount, uint256 _timepoint)
    internal
  {
    DelegationAdjustment[] memory _votes = tokenProxy.exposed_calculateWeightDistribution(_delegations, _amount);
    uint256 _totalWeight = 0;
    for (uint256 i = 0; i < _delegations.length; i++) {
      uint256 _expectedVoteWeight = _votes[i]._amount;
      assertEq(
        tokenProxy.getPastVotes(_delegations[i]._delegatee, _timepoint),
        _expectedVoteWeight,
        "incorrect past vote weight for delegate"
      );
      _totalWeight += _votes[i]._amount;
    }
    assertLe(_totalWeight, _amount, "incorrect total weight");
  }

  function _mint(address _to, uint256 _amount) internal {
    vm.prank(_to);
    tokenProxy.mint(_amount);
  }

  function _createSingleFullDelegation(address _delegatee) internal view returns (PartialDelegation[] memory) {
    PartialDelegation[] memory delegations = new PartialDelegation[](1);
    delegations[0] = PartialDelegation(_delegatee, tokenProxy.DENOMINATOR());
    return delegations;
  }

  function _expectEmitDelegateChangedEvents(
    address _delegator,
    PartialDelegation[] memory _oldDelegations,
    PartialDelegation[] memory _newDelegations
  ) internal {
    uint256 i;
    uint256 j;
    while (i < _oldDelegations.length || j < _newDelegations.length) {
      // If both delegations have the same delegatee
      if (
        i < _oldDelegations.length && j < _newDelegations.length
          && _oldDelegations[i]._delegatee == _newDelegations[j]._delegatee
      ) {
        // if the numerator is different
        if (_oldDelegations[i]._numerator != _newDelegations[j]._numerator) {
          vm.expectEmit();
          emit DelegateChanged(_delegator, _newDelegations[j]._delegatee, _newDelegations[j]._numerator);
        }
        i++;
        j++;
        // Old delegatee comes before the new delegatee OR new delegatees have been exhausted
      } else if (
        j == _newDelegations.length
          || (i != _oldDelegations.length && _oldDelegations[i]._delegatee < _newDelegations[j]._delegatee)
      ) {
        vm.expectEmit();
        emit DelegateChanged(_delegator, _oldDelegations[i]._delegatee, 0);
        i++;
        // If new delegatee comes before the old delegatee OR old delegatees have been exhausted
      } else {
        vm.expectEmit();
        emit DelegateChanged(_delegator, _newDelegations[j]._delegatee, _newDelegations[j]._numerator);
        j++;
      }
    }
  }

  function _expectEmitDelegateVotesChangedEvents(
    uint256 _amount,
    uint256 _toExistingBalance,
    PartialDelegation[] memory _fromPartialDelegations,
    PartialDelegation[] memory _toPartialDelegations
  ) internal {
    DelegationAdjustment[] memory _fromVotes =
      tokenProxy.exposed_calculateWeightDistribution(_fromPartialDelegations, _amount);
    DelegationAdjustment[] memory _toInitialVotes =
      tokenProxy.exposed_calculateWeightDistribution(_toPartialDelegations, _toExistingBalance);
    DelegationAdjustment[] memory _toVotes =
      tokenProxy.exposed_calculateWeightDistribution(_toPartialDelegations, _amount + _toExistingBalance);

    uint256 i;
    uint256 j;
    while (i < _fromPartialDelegations.length || j < _toPartialDelegations.length) {
      // If both delegations have the same delegatee
      if (
        i < _fromPartialDelegations.length && j < _toPartialDelegations.length
          && _fromPartialDelegations[i]._delegatee == _toPartialDelegations[j]._delegatee
      ) {
        // if the numerator is different
        if (_fromPartialDelegations[i]._numerator != _toPartialDelegations[j]._numerator) {
          if (_toVotes[j]._amount != 0 || _fromVotes[j]._amount != 0) {
            vm.expectEmit();
            emit DelegateVotesChanged(_fromPartialDelegations[i]._delegatee, _fromVotes[j]._amount, _toVotes[j]._amount);
          }
        }
        i++;
        j++;
        // Old delegatee comes before the new delegatee OR new delegatees have been exhausted
      } else if (
        j == _toPartialDelegations.length
          || (
            i != _fromPartialDelegations.length
              && _fromPartialDelegations[i]._delegatee < _toPartialDelegations[j]._delegatee
          )
      ) {
        if (_fromVotes[i]._amount != 0) {
          vm.expectEmit();
          emit DelegateVotesChanged(_fromPartialDelegations[i]._delegatee, _fromVotes[i]._amount, 0);
        }
        i++;
        // If new delegatee comes before the old delegatee OR old delegatees have been exhausted
      } else {
        // If the new delegatee vote weight is not the same as its previous vote weight
        if (_toVotes[j]._amount != 0 && _toVotes[j]._amount != _toInitialVotes[j]._amount) {
          vm.expectEmit();
          emit DelegateVotesChanged(
            _toPartialDelegations[j]._delegatee, _toInitialVotes[j]._amount, _toVotes[j]._amount
          );
        }
        j++;
      }
    }
  }

  function _sign(uint256 _privateKey, bytes32 _messageHash) internal pure returns (bytes memory) {
    (uint8 _v, bytes32 _r, bytes32 _s) = vm.sign(_privateKey, _messageHash);
    return abi.encodePacked(_r, _s, _v);
  }

  function _hash(PartialDelegation memory partialDelegation) internal view returns (bytes32) {
    return keccak256(
      abi.encode(tokenProxy.PARTIAL_DELEGATION_TYPEHASH(), partialDelegation._delegatee, partialDelegation._numerator)
    );
  }
}

contract Delegate is PartialDelegationTest {
  function testFuzz_DelegatesToAnySingleNonZeroAddress(
    address _actor,
    address _delegatee,
    uint96 _numerator,
    uint256 _amount
  ) public {
    vm.assume(_actor != address(0));
    vm.assume(_delegatee != address(0));
    _numerator = uint96(bound(_numerator, 1, tokenProxy.DENOMINATOR()));
    _amount = bound(_amount, 0, type(uint208).max);
    vm.startPrank(_actor);
    tokenProxy.mint(_amount);
    PartialDelegation[] memory delegations = new PartialDelegation[](1);
    delegations[0] = PartialDelegation(_delegatee, _numerator);
    tokenProxy.delegate(delegations);
    vm.stopPrank();
    assertEq(tokenProxy.delegates(_actor), delegations);
    DelegationAdjustment[] memory adjustments = tokenProxy.exposed_calculateWeightDistribution(delegations, _amount);
    assertEq(tokenProxy.getVotes(_delegatee), adjustments[0]._amount);
  }

  function testFuzz_DelegatesOnlyToZeroAddress(address _actor, uint96 _numerator, uint256 _amount) public {
    vm.assume(_actor != address(0));
    address _delegatee = address(0);
    _numerator = uint96(bound(_numerator, 1, tokenProxy.DENOMINATOR()));
    _amount = bound(_amount, 0, type(uint208).max);
    vm.startPrank(_actor);
    tokenProxy.mint(_amount);
    PartialDelegation[] memory delegations = new PartialDelegation[](1);
    delegations[0] = PartialDelegation(_delegatee, _numerator);
    tokenProxy.delegate(delegations);
    vm.stopPrank();
    assertEq(tokenProxy.delegates(_actor), delegations);
    assertEq(tokenProxy.getVotes(_delegatee), 0);
  }

  function testFuzz_DelegatesToTwoAddresses(
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
    _numerator2 = uint96(bound(_numerator2, 1, tokenProxy.DENOMINATOR() - _numerator1));
    vm.startPrank(_actor);
    tokenProxy.mint(_amount);
    PartialDelegation[] memory delegations = new PartialDelegation[](2);
    delegations[0] = PartialDelegation(_delegatee1, _numerator1);
    delegations[1] = PartialDelegation(_delegatee2, _numerator2);
    tokenProxy.delegate(delegations);
    vm.stopPrank();
    assertEq(tokenProxy.delegates(_actor), delegations);
    assertCorrectVotes(delegations, _amount);
  }

  function testFuzz_DelegatesToNAddresses(address _actor, uint256 _amount, uint256 _n, uint256 _seed) public {
    vm.assume(_actor != address(0));
    _amount = bound(_amount, 0, type(uint208).max);
    _n = bound(_n, 1, tokenProxy.MAX_PARTIAL_DELEGATIONS());
    PartialDelegation[] memory delegations = _createValidPartialDelegation(_n, _seed);
    vm.startPrank(_actor);
    tokenProxy.mint(_amount);
    tokenProxy.delegate(delegations);
    vm.stopPrank();
    assertEq(tokenProxy.delegates(_actor), delegations);
    assertCorrectVotes(delegations, _amount);
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
    assertCorrectVotes(newDelegations, _amount);
    // initial delegates should have 0 vote power (assuming set union is empty)
    for (uint256 i = 0; i < delegations.length; i++) {
      assertEq(tokenProxy.getVotes(delegations[i]._delegatee), 0, "initial delegate has vote power");
    }
  }

  function testFuzz_EmitsDelegateChangedEvents(address _actor, uint256 _amount, uint256 _n, uint256 _seed) public {
    vm.assume(_actor != address(0));
    _amount = bound(_amount, 0, type(uint208).max);
    _n = bound(_n, 1, tokenProxy.MAX_PARTIAL_DELEGATIONS());
    PartialDelegation[] memory delegations = _createValidPartialDelegation(_n, _seed);
    vm.startPrank(_actor);
    tokenProxy.mint(_amount);

    _expectEmitDelegateChangedEvents(_actor, new PartialDelegation[](0), delegations);
    tokenProxy.delegate(delegations);
    vm.stopPrank();
  }

  function testFuzz_EmitsDelegateVotesChanged(address _actor, uint256 _amount, uint256 _n, uint256 _seed) public {
    vm.assume(_actor != address(0));
    _amount = bound(_amount, 0, type(uint208).max);
    _n = bound(_n, 1, tokenProxy.MAX_PARTIAL_DELEGATIONS());
    PartialDelegation[] memory delegations = _createValidPartialDelegation(_n, _seed);
    vm.startPrank(_actor);
    tokenProxy.mint(_amount);

    _expectEmitDelegateVotesChangedEvents(_amount, new PartialDelegation[](0), delegations);
    tokenProxy.delegate(delegations);
    vm.stopPrank();
  }

  function testFuzz_EmitsDelegateChangedEventsWhenDelegateesAreRemoved(
    address _actor,
    uint256 _amount,
    uint256 _oldN,
    uint256 _numOfDelegateesToRemove,
    uint256 _seed
  ) public {
    vm.assume(_actor != address(0));
    _amount = bound(_amount, 0, type(uint208).max);
    _oldN = bound(_oldN, 1, tokenProxy.MAX_PARTIAL_DELEGATIONS());
    _numOfDelegateesToRemove = bound(_numOfDelegateesToRemove, 0, _oldN - 1);
    PartialDelegation[] memory oldDelegations = _createValidPartialDelegation(_oldN, _seed);
    vm.startPrank(_actor);
    tokenProxy.mint(_amount);
    tokenProxy.delegate(oldDelegations);

    PartialDelegation[] memory newDelegations = new PartialDelegation[](_oldN - _numOfDelegateesToRemove);
    for (uint256 i; i < newDelegations.length; i++) {
      newDelegations[i] = oldDelegations[i];
    }

    _expectEmitDelegateChangedEvents(_actor, oldDelegations, newDelegations);
    tokenProxy.delegate(newDelegations);
    vm.stopPrank();
  }

  function testFuzz_EmitsDelegateChangedEventsWhenAllNumeratorsForCurrentDelegateesAreChanged(
    address _actor,
    uint256 _amount,
    uint256 _oldN,
    uint256 _newN,
    uint256 _seed
  ) public {
    vm.assume(_actor != address(0));
    _amount = bound(_amount, 0, type(uint208).max);
    _oldN = bound(_oldN, 1, tokenProxy.MAX_PARTIAL_DELEGATIONS());
    _newN = bound(_newN, 1, tokenProxy.MAX_PARTIAL_DELEGATIONS());
    PartialDelegation[] memory oldDelegations = _createValidPartialDelegation(_oldN, _seed);
    vm.startPrank(_actor);
    tokenProxy.mint(_amount);
    tokenProxy.delegate(oldDelegations);
    PartialDelegation[] memory newDelegations = oldDelegations;

    // Arthimatic overflow/underflow error without this bounding.
    _seed = bound(
      _seed,
      1,
      /* private key can't be bigger than secp256k1 curve order */
      115_792_089_237_316_195_423_570_985_008_687_907_852_837_564_279_074_904_382_605_163_141_518_161_494_337 - 1
    );
    uint96 _totalNumerator;
    for (uint256 i = 0; i < _oldN; i++) {
      uint96 _numerator = uint96(
        bound(
          uint256(keccak256(abi.encode(_seed + i))) % tokenProxy.DENOMINATOR(), // initial value of the numerator
          1,
          tokenProxy.DENOMINATOR() - _totalNumerator - (_oldN - i) // ensure that there is enough numerator left for the
            // remaining delegations
        )
      );
      newDelegations[i]._numerator = _numerator;
      _totalNumerator += _numerator;
    }

    _expectEmitDelegateChangedEvents(_actor, oldDelegations, newDelegations);
    tokenProxy.delegate(newDelegations);
    vm.stopPrank();
  }

  function testFuzz_EmitsDelegateChangedEventsWhenAllDelegatesAreReplaced(
    address _actor,
    uint256 _amount,
    uint256 _oldN,
    uint256 _newN,
    uint256 _seed
  ) public {
    vm.assume(_actor != address(0));
    _amount = bound(_amount, 0, type(uint208).max);
    _oldN = bound(_oldN, 1, tokenProxy.MAX_PARTIAL_DELEGATIONS());
    _newN = bound(_newN, 1, tokenProxy.MAX_PARTIAL_DELEGATIONS());
    PartialDelegation[] memory oldDelegations = _createValidPartialDelegation(_oldN, _seed);
    vm.startPrank(_actor);
    tokenProxy.mint(_amount);
    tokenProxy.delegate(oldDelegations);

    PartialDelegation[] memory newDelegations =
      _createValidPartialDelegation(_newN, uint256(keccak256(abi.encode(_seed))));
    _expectEmitDelegateChangedEvents(_actor, oldDelegations, newDelegations);
    tokenProxy.delegate(newDelegations);
    vm.stopPrank();
  }

  function testFuzz_EmitsDelegateVotesChangedEventsWhenAllNumeratorsForCurrentDelegateesAreChanged(
    address _actor,
    uint256 _amount,
    uint256 _oldN,
    uint256 _newN,
    uint256 _seed
  ) public {
    vm.assume(_actor != address(0));
    _amount = bound(_amount, 0, type(uint208).max);
    _oldN = bound(_oldN, 1, tokenProxy.MAX_PARTIAL_DELEGATIONS());
    _newN = bound(_newN, 1, tokenProxy.MAX_PARTIAL_DELEGATIONS());
    PartialDelegation[] memory oldDelegations = _createValidPartialDelegation(_oldN, _seed);
    vm.startPrank(_actor);
    tokenProxy.mint(_amount);
    tokenProxy.delegate(oldDelegations);
    PartialDelegation[] memory newDelegations = oldDelegations;

    _seed = bound(
      _seed,
      1,
      /* private key can't be bigger than secp256k1 curve order */
      115_792_089_237_316_195_423_570_985_008_687_907_852_837_564_279_074_904_382_605_163_141_518_161_494_337 - 1
    );
    uint96 _totalNumerator;
    for (uint256 i = 0; i < _oldN; i++) {
      uint96 _numerator = uint96(
        bound(
          uint256(keccak256(abi.encode(_seed + i))) % tokenProxy.DENOMINATOR(), // initial value of the numerator
          1,
          tokenProxy.DENOMINATOR() - _totalNumerator - (_oldN - i) // ensure that there is enough numerator left for the
            // remaining delegations
        )
      );
      newDelegations[i]._numerator = _numerator;
      _totalNumerator += _numerator;
    }

    _expectEmitDelegateVotesChangedEvents(_amount, oldDelegations, newDelegations);
    tokenProxy.delegate(newDelegations);
    vm.stopPrank();
  }

  function testFuzz_EmitsDelegateVotesChangedEventsWhenDelegateesAreRemoved(
    address _actor,
    uint256 _amount,
    uint256 _oldN,
    uint256 _numOfDelegateesToRemove,
    uint256 _seed
  ) public {
    vm.assume(_actor != address(0));
    _amount = bound(_amount, 0, type(uint208).max);
    _oldN = bound(_oldN, 1, tokenProxy.MAX_PARTIAL_DELEGATIONS());
    _numOfDelegateesToRemove = bound(_numOfDelegateesToRemove, 0, _oldN - 1);
    PartialDelegation[] memory oldDelegations = _createValidPartialDelegation(_oldN, _seed);
    vm.startPrank(_actor);
    tokenProxy.mint(_amount);
    tokenProxy.delegate(oldDelegations);

    PartialDelegation[] memory newDelegations = new PartialDelegation[](_oldN - _numOfDelegateesToRemove);
    for (uint256 i; i < newDelegations.length; i++) {
      newDelegations[i] = oldDelegations[i];
    }

    _expectEmitDelegateVotesChangedEvents(_amount, oldDelegations, newDelegations);
    tokenProxy.delegate(newDelegations);
    vm.stopPrank();
  }

  function testFuzz_EmitsDelegateVotesChangedEventsWhenAllDelegatesAreReplaced(
    address _actor,
    uint256 _amount,
    uint256 _oldN,
    uint256 _newN,
    uint256 _seed
  ) public {
    vm.assume(_actor != address(0));
    _amount = bound(_amount, 0, type(uint208).max);
    _oldN = bound(_oldN, 1, tokenProxy.MAX_PARTIAL_DELEGATIONS());
    _newN = bound(_newN, 1, tokenProxy.MAX_PARTIAL_DELEGATIONS());

    PartialDelegation[] memory oldDelegations = _createValidPartialDelegation(_oldN, _seed);
    vm.startPrank(_actor);
    tokenProxy.mint(_amount);
    tokenProxy.delegate(oldDelegations);

    PartialDelegation[] memory newDelegations =
      _createValidPartialDelegation(_newN, uint256(keccak256(abi.encode(_seed))));
    _expectEmitDelegateVotesChangedEvents(_amount, oldDelegations, newDelegations);
    tokenProxy.delegate(newDelegations);
    vm.stopPrank();
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

  function testFuzz_RevertIf_PartialDelegationLimitExceeded(
    address _actor,
    uint256 _amount,
    uint256 _numOfDelegatees,
    uint256 _seed
  ) public {
    vm.assume(_actor != address(0));
    _amount = bound(_amount, 0, type(uint208).max);
    _numOfDelegatees =
      bound(_numOfDelegatees, tokenProxy.MAX_PARTIAL_DELEGATIONS() + 1, tokenProxy.MAX_PARTIAL_DELEGATIONS() + 500);
    PartialDelegation[] memory delegations = _createValidPartialDelegation(_numOfDelegatees, _seed);
    vm.startPrank(_actor);
    tokenProxy.mint(_amount);
    vm.expectRevert(
      abi.encodeWithSelector(
        PartialDelegationLimitExceeded.selector, _numOfDelegatees, tokenProxy.MAX_PARTIAL_DELEGATIONS()
      )
    );
    tokenProxy.delegate(delegations);
    vm.stopPrank();
  }

  function testFuzz_RevertIf_DuplicateOrUnsortedDelegatees(
    address _actor,
    uint256 _amount,
    uint256 _numOfDelegatees,
    address _replacedDelegatee,
    uint256 _seed
  ) public {
    vm.assume(_actor != address(0));
    _amount = bound(_amount, 0, type(uint208).max);
    _numOfDelegatees = bound(_numOfDelegatees, 2, tokenProxy.MAX_PARTIAL_DELEGATIONS());
    PartialDelegation[] memory delegations = _createValidPartialDelegation(_numOfDelegatees, _seed);
    address lastDelegatee = delegations[delegations.length - 1]._delegatee;
    vm.assume(_replacedDelegatee <= lastDelegatee);
    delegations[delegations.length - 1]._delegatee = _replacedDelegatee;

    vm.startPrank(_actor);
    tokenProxy.mint(_amount);
    vm.expectRevert(abi.encodeWithSelector(DuplicateOrUnsortedDelegatees.selector, _replacedDelegatee));
    tokenProxy.delegate(delegations);
    vm.stopPrank();
  }

  function testFuzz_RevertIf_InvalidNumeratorZero(
    address _actor,
    uint256 _amount,
    uint256 _delegationIndex,
    uint256 _seed
  ) public {
    vm.assume(_actor != address(0));
    _amount = bound(_amount, 0, type(uint208).max);
    PartialDelegation[] memory delegations = _createValidPartialDelegation(0, _seed);
    _delegationIndex = bound(_delegationIndex, 0, delegations.length - 1);

    delegations[_delegationIndex]._numerator = 0;

    vm.startPrank(_actor);
    tokenProxy.mint(_amount);
    vm.expectRevert(InvalidNumeratorZero.selector);
    tokenProxy.delegate(delegations);
    vm.stopPrank();
  }

  function testFuzz_RevertIf_NumeratorSumExceedsDenominator(
    address _actor,
    uint256 _amount,
    uint256 _delegationIndex,
    uint256 _seed
  ) public {
    vm.assume(_actor != address(0));
    _amount = bound(_amount, 0, type(uint208).max);
    PartialDelegation[] memory delegations = _createValidPartialDelegation(0, _seed);
    _delegationIndex = bound(_delegationIndex, 0, delegations.length - 1);

    delegations[_delegationIndex]._numerator = tokenProxy.DENOMINATOR() + 1;
    uint256 sumOfNumerators;
    for (uint256 i; i < delegations.length; i++) {
      sumOfNumerators += delegations[i]._numerator;
    }

    vm.startPrank(_actor);
    tokenProxy.mint(_amount);
    vm.expectRevert(
      abi.encodeWithSelector(NumeratorSumExceedsDenominator.selector, sumOfNumerators, tokenProxy.DENOMINATOR())
    );
    tokenProxy.delegate(delegations);
    vm.stopPrank();
  }
}

contract DelegateLegacy is PartialDelegationTest {
  function testFuzz_DelegatesSuccessfullyToNonZeroAddress(
    uint256 _delegatorPrivateKey,
    address _delegatee,
    uint256 _delegatorBalance,
    uint256 _deadline
  ) public {
    vm.assume(_delegatee != address(0));
    _delegatorPrivateKey = bound(_delegatorPrivateKey, 1, 100e18);
    address _delegator = vm.addr(_delegatorPrivateKey);
    _delegatorBalance = bound(_delegatorBalance, 0, type(uint208).max);
    _deadline = bound(_deadline, block.timestamp, type(uint256).max);
    _mint(_delegator, _delegatorBalance);

    vm.prank(_delegator);
    tokenProxy.delegate(_delegatee);
    assertEq(tokenProxy.delegates(_delegator), _createSingleFullDelegation(_delegatee));
    assertEq(tokenProxy.getVotes(_delegatee), _delegatorBalance);
  }

  function testFuzz_DelegatesSuccessfullyToZeroAddress(
    uint256 _delegatorPrivateKey,
    uint256 _delegatorBalance,
    uint256 _deadline
  ) public {
    address _delegatee = address(0);
    _delegatorPrivateKey = bound(_delegatorPrivateKey, 1, 100e18);
    address _delegator = vm.addr(_delegatorPrivateKey);
    _delegatorBalance = bound(_delegatorBalance, 0, type(uint208).max);
    _deadline = bound(_deadline, block.timestamp, type(uint256).max);
    _mint(_delegator, _delegatorBalance);

    vm.prank(_delegator);
    tokenProxy.delegate(_delegatee);
    assertEq(tokenProxy.delegates(_delegator), _createSingleFullDelegation(_delegatee));
    assertEq(tokenProxy.getVotes(_delegatee), 0);
  }

  function testFuzz_RedelegatesSuccessfully(
    uint256 _delegatorPrivateKey,
    address _delegatee,
    address _newDelegatee,
    uint256 _delegatorBalance,
    uint256 _deadline
  ) public {
    _delegatorPrivateKey = bound(_delegatorPrivateKey, 1, 100e18);
    address _delegator = vm.addr(_delegatorPrivateKey);
    _delegatorBalance = bound(_delegatorBalance, 0, type(uint208).max);
    _deadline = bound(_deadline, block.timestamp, type(uint256).max);
    _mint(_delegator, _delegatorBalance);

    vm.prank(_delegator);
    tokenProxy.delegate(_delegatee);
    assertEq(tokenProxy.delegates(_delegator), _createSingleFullDelegation(_delegatee));
    uint256 _expectedVotes = _delegatee == address(0) ? 0 : _delegatorBalance;
    assertEq(tokenProxy.getVotes(_delegatee), _expectedVotes);

    vm.prank(_delegator);
    tokenProxy.delegate(_newDelegatee);
    assertEq(tokenProxy.delegates(_delegator), _createSingleFullDelegation(_newDelegatee));
    _expectedVotes = _newDelegatee == address(0) ? 0 : _delegatorBalance;
    assertEq(tokenProxy.getVotes(_newDelegatee), _expectedVotes);
  }

  function testFuzz_RedelegatesToAPartialDelegationSuccessfully(
    uint256 _delegatorPrivateKey,
    address _delegatee,
    uint256 _delegatorBalance,
    uint256 _deadline,
    uint256 _seed
  ) public {
    _delegatorPrivateKey = bound(_delegatorPrivateKey, 1, 100e18);
    address _delegator = vm.addr(_delegatorPrivateKey);
    _delegatorBalance = bound(_delegatorBalance, 0, type(uint208).max);
    _deadline = bound(_deadline, block.timestamp, type(uint256).max);
    _mint(_delegator, _delegatorBalance);

    vm.prank(_delegator);
    tokenProxy.delegate(_delegatee);
    assertEq(tokenProxy.delegates(_delegator), _createSingleFullDelegation(_delegatee));
    uint256 _expectedVotes = _delegatee == address(0) ? 0 : _delegatorBalance;
    assertEq(tokenProxy.getVotes(_delegatee), _expectedVotes);

    PartialDelegation[] memory newDelegations = _createValidPartialDelegation(0, uint256(keccak256(abi.encode(_seed))));
    vm.prank(_delegator);
    tokenProxy.delegate(newDelegations);
    assertEq(tokenProxy.delegates(_delegator), newDelegations);
    assertCorrectVotes(newDelegations, _delegatorBalance);
  }
}

contract DelegateBySig is PartialDelegationTest {
  using stdStorage for StdStorage;

  function testFuzz_DelegatesSuccessfullyToNonZeroAddress(
    address _actor,
    uint256 _delegatorPrivateKey,
    address _delegatee,
    uint256 _delegatorBalance,
    uint256 _currentNonce,
    uint256 _deadline
  ) public {
    vm.assume(_actor != address(0));
    vm.assume(_delegatee != address(0));
    _delegatorPrivateKey = bound(_delegatorPrivateKey, 1, 100e18);
    address _delegator = vm.addr(_delegatorPrivateKey);
    stdstore.target(address(tokenProxy)).sig("nonces(address)").with_key(_delegator).checked_write(_currentNonce);
    _delegatorBalance = bound(_delegatorBalance, 0, type(uint208).max);
    _deadline = bound(_deadline, block.timestamp, type(uint256).max);
    _mint(_delegator, _delegatorBalance);

    bytes32 _message = keccak256(abi.encode(tokenProxy.DELEGATION_TYPEHASH(), _delegatee, _currentNonce, _deadline));

    bytes32 _messageHash = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, _message));
    (uint8 _v, bytes32 _r, bytes32 _s) = vm.sign(_delegatorPrivateKey, _messageHash);
    vm.prank(_actor);
    tokenProxy.delegateBySig(_delegatee, _currentNonce, _deadline, _v, _r, _s);
    assertEq(tokenProxy.delegates(_delegator), _createSingleFullDelegation(_delegatee));
    assertEq(tokenProxy.getVotes(_delegatee), _delegatorBalance);
  }

  function testFuzz_DelegatesSuccessfullyToZeroAddress(
    address _actor,
    uint256 _delegatorPrivateKey,
    uint256 _delegatorBalance,
    uint256 _currentNonce,
    uint256 _deadline
  ) public {
    vm.assume(_actor != address(0));
    address _delegatee = address(0);
    _delegatorPrivateKey = bound(_delegatorPrivateKey, 1, 100e18);
    address _delegator = vm.addr(_delegatorPrivateKey);
    stdstore.target(address(tokenProxy)).sig("nonces(address)").with_key(_delegator).checked_write(_currentNonce);
    _delegatorBalance = bound(_delegatorBalance, 0, type(uint208).max);
    _deadline = bound(_deadline, block.timestamp, type(uint256).max);
    _mint(_delegator, _delegatorBalance);

    bytes32 _message = keccak256(abi.encode(tokenProxy.DELEGATION_TYPEHASH(), address(0), _currentNonce, _deadline));

    bytes32 _messageHash = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, _message));
    (uint8 _v, bytes32 _r, bytes32 _s) = vm.sign(_delegatorPrivateKey, _messageHash);
    vm.prank(_actor);
    tokenProxy.delegateBySig(_delegatee, _currentNonce, _deadline, _v, _r, _s);
    assertEq(tokenProxy.delegates(_delegator), _createSingleFullDelegation(_delegatee));
    assertEq(tokenProxy.getVotes(_delegatee), 0);
  }

  function testFuzz_RevertIf_DelegatesViaERC712SignatureWithExpiredDeadline(
    address _actor,
    uint256 _delegatorPrivateKey,
    address _delegatee,
    uint256 _delegatorBalance,
    uint256 _currentNonce,
    uint256 _currentTimestamp,
    uint256 _deadline
  ) public {
    vm.assume(_actor != address(0));
    _delegatorPrivateKey = bound(_delegatorPrivateKey, 1, 100e18);
    address _delegator = vm.addr(_delegatorPrivateKey);
    stdstore.target(address(tokenProxy)).sig("nonces(address)").with_key(_delegator).checked_write(_currentNonce);
    _delegatorBalance = bound(_delegatorBalance, 0, type(uint208).max);
    _currentTimestamp = bound(_currentTimestamp, 1, type(uint256).max);
    vm.warp(_currentTimestamp);
    _deadline = bound(_deadline, 0, _currentTimestamp - 1);
    _mint(_delegator, _delegatorBalance);

    bytes32 _message = keccak256(abi.encode(tokenProxy.DELEGATION_TYPEHASH(), _delegatee, _currentNonce, _deadline));

    bytes32 _messageHash = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, _message));
    (uint8 _v, bytes32 _r, bytes32 _s) = vm.sign(_delegatorPrivateKey, _messageHash);
    vm.prank(_actor);
    vm.expectRevert(abi.encodeWithSelector(VotesExpiredSignature.selector, _deadline));
    tokenProxy.delegateBySig(_delegatee, _currentNonce, _deadline, _v, _r, _s);
  }

  function testFuzz_RevertIf_DelegatesViaERC712SignatureWithWrongNonce(
    address _actor,
    uint256 _delegatorPrivateKey,
    address _delegatee,
    uint256 _delegatorBalance,
    uint256 _currentNonce,
    uint256 _suppliedNonce,
    uint256 _deadline
  ) public {
    vm.assume(_actor != address(0));
    vm.assume(_suppliedNonce != _currentNonce);
    _delegatorPrivateKey = bound(_delegatorPrivateKey, 1, 100e18);
    address _delegator = vm.addr(_delegatorPrivateKey);
    stdstore.target(address(tokenProxy)).sig("nonces(address)").with_key(_delegator).checked_write(_currentNonce);
    _delegatorBalance = bound(_delegatorBalance, 0, type(uint208).max);
    _deadline = bound(_deadline, block.timestamp, type(uint256).max);
    _mint(_delegator, _delegatorBalance);

    bytes32 _message = keccak256(abi.encode(tokenProxy.DELEGATION_TYPEHASH(), _delegatee, _suppliedNonce, _deadline));

    bytes32 _messageHash = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, _message));
    (uint8 _v, bytes32 _r, bytes32 _s) = vm.sign(_delegatorPrivateKey, _messageHash);
    vm.prank(_actor);
    vm.expectRevert(abi.encodeWithSelector(InvalidAccountNonce.selector, _delegator, tokenProxy.nonces(_delegator)));
    tokenProxy.delegateBySig(_delegatee, _suppliedNonce, _deadline, _v, _r, _s);
  }

  function testFuzz_RevertIf_DelegatesViaInvalidERC712Signature(
    address _actor,
    uint256 _delegatorPrivateKey,
    address _delegatee,
    uint256 _delegatorBalance,
    uint256 _currentNonce,
    uint256 _deadline,
    uint256 _randomSeed
  ) public {
    vm.assume(_actor != address(0));
    _delegatorPrivateKey = bound(_delegatorPrivateKey, 1, 100e18);
    address _delegator = vm.addr(_delegatorPrivateKey);
    stdstore.target(address(tokenProxy)).sig("nonces(address)").with_key(_delegator).checked_write(_currentNonce);
    _delegatorBalance = bound(_delegatorBalance, 0, type(uint208).max);
    _deadline = bound(_deadline, block.timestamp, type(uint256).max);
    _mint(_delegator, _delegatorBalance);

    bytes32 _message = keccak256(abi.encode(tokenProxy.DELEGATION_TYPEHASH(), _delegatee, _currentNonce, _deadline));
    bytes32 _messageHash = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, _message));

    // Here we use `_randomSeed` as an arbitrary source of randomness to replace a legit parameter
    // with an attack-like one.
    if (_randomSeed % 3 == 0) {
      _delegatee = address(uint160(uint256(keccak256(abi.encode(_delegatee)))));
    } else if (_randomSeed % 3 == 1) {
      _currentNonce = uint256(keccak256(abi.encode(_currentNonce)));
    }
    (uint8 _v, bytes32 _r, bytes32 _s) = vm.sign(_delegatorPrivateKey, _messageHash);
    if (_randomSeed % 3 == 2) {
      (_v, _r, _s) = vm.sign(uint256(keccak256(abi.encode(_delegatorPrivateKey))), _messageHash);
    }

    vm.prank(_actor);
    try tokenProxy.delegateBySig(_delegatee, _currentNonce, _deadline, _v, _r, _s) {} catch {}
    assertEq(tokenProxy.delegates(_delegator), new PartialDelegation[](0));
  }
}

contract DelegatePartiallyOnBehalf is PartialDelegationTest {
  using stdStorage for StdStorage;

  function testFuzz_DelegatesSuccessfullyViaERC712Signer(
    address _actor,
    uint256 _delegatorPrivateKey,
    uint256 _delegationSeed,
    uint256 _delegatorBalance,
    uint256 _currentNonce,
    uint256 _deadline
  ) public {
    vm.assume(_actor != address(0));
    _delegatorPrivateKey = bound(_delegatorPrivateKey, 1, 100e18);
    address _delegator = vm.addr(_delegatorPrivateKey);
    stdstore.target(address(tokenProxy)).sig("nonces(address)").with_key(_delegator).checked_write(_currentNonce);
    _delegatorBalance = bound(_delegatorBalance, 0, type(uint208).max);
    _deadline = bound(_deadline, block.timestamp, type(uint256).max);
    _mint(_delegator, _delegatorBalance);

    PartialDelegation[] memory _delegations = _createValidPartialDelegation(0, _delegationSeed);

    bytes32[] memory _payload = new bytes32[](_delegations.length);
    for (uint256 i; i < _delegations.length; i++) {
      _payload[i] = _hash(_delegations[i]);
    }

    bytes32 _message = keccak256(
      abi.encode(
        tokenProxy.PARTIAL_DELEGATION_ON_BEHALF_TYPEHASH(),
        _delegator,
        keccak256(abi.encodePacked(_payload)),
        _currentNonce,
        _deadline
      )
    );

    bytes32 _messageHash = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, _message));
    bytes memory _signature = _sign(_delegatorPrivateKey, _messageHash);
    vm.prank(_actor);
    tokenProxy.delegatePartiallyOnBehalf(_delegator, _delegations, _currentNonce, _deadline, _signature);
    assertEq(tokenProxy.delegates(_delegator), _delegations);
  }

  function testFuzz_DelegatesSuccessfullyViaERC1271Signer(
    address _actor,
    uint256 _delegationSeed,
    uint256 _delegatorBalance,
    uint256 _currentNonce,
    uint256 _deadline,
    bytes memory _signature
  ) public {
    vm.assume(_actor != address(0));
    MockERC1271Signer _erc1271Signer = new MockERC1271Signer();
    _erc1271Signer.setResponse__isValidSignature(true);
    address _delegator = address(_erc1271Signer);
    stdstore.target(address(tokenProxy)).sig("nonces(address)").with_key(address(_delegator)).checked_write(
      _currentNonce
    );
    _delegatorBalance = bound(_delegatorBalance, 0, type(uint208).max);
    _deadline = bound(_deadline, block.timestamp, type(uint256).max);
    _mint(_delegator, _delegatorBalance);

    PartialDelegation[] memory _delegations = _createValidPartialDelegation(0, _delegationSeed);

    bytes32[] memory _payload = new bytes32[](_delegations.length);
    for (uint256 i; i < _delegations.length; i++) {
      _payload[i] = _hash(_delegations[i]);
    }

    vm.prank(_actor);
    tokenProxy.delegatePartiallyOnBehalf(_delegator, _delegations, _currentNonce, _deadline, _signature);
    assertEq(tokenProxy.delegates(_delegator), _delegations);
  }

  function testFuzz_RevertIf_DelegatesViaERC712SignerWithWrongNonce(
    address _actor,
    uint256 _delegatorPrivateKey,
    uint256 _delegationSeed,
    uint256 _delegatorBalance,
    uint256 _currentNonce,
    uint256 _suppliedNonce,
    uint256 _deadline
  ) public {
    vm.assume(_actor != address(0));
    vm.assume(_suppliedNonce != _currentNonce);
    _delegatorPrivateKey = bound(_delegatorPrivateKey, 1, 100e18);
    address _delegator = vm.addr(_delegatorPrivateKey);
    stdstore.target(address(tokenProxy)).sig("nonces(address)").with_key(_delegator).checked_write(_currentNonce);
    _delegatorBalance = bound(_delegatorBalance, 0, type(uint208).max);
    _deadline = bound(_deadline, block.timestamp, type(uint256).max);
    _mint(_delegator, _delegatorBalance);

    PartialDelegation[] memory _delegations = _createValidPartialDelegation(0, _delegationSeed);

    bytes32[] memory _payload = new bytes32[](_delegations.length);
    for (uint256 i; i < _delegations.length; i++) {
      _payload[i] = _hash(_delegations[i]);
    }

    bytes32 _message = keccak256(
      abi.encode(
        tokenProxy.PARTIAL_DELEGATION_ON_BEHALF_TYPEHASH(),
        _delegator,
        keccak256(abi.encodePacked(_payload)),
        _suppliedNonce,
        _deadline
      )
    );

    bytes32 _messageHash = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, _message));
    bytes memory _signature = _sign(_delegatorPrivateKey, _messageHash);
    vm.prank(_actor);
    vm.expectRevert(abi.encodeWithSelector(InvalidAccountNonce.selector, _delegator, tokenProxy.nonces(_delegator)));
    tokenProxy.delegatePartiallyOnBehalf(_delegator, _delegations, _suppliedNonce, _deadline, _signature);
  }

  function testFuzz_RevertIf_DelegatesViaERC712SignatureWithExpiredDeadline(
    address _actor,
    uint256 _delegatorPrivateKey,
    uint256 _delegationSeed,
    uint256 _delegatorBalance,
    uint256 _currentNonce,
    uint256 _currentTimeStamp,
    uint256 _deadline
  ) public {
    vm.assume(_actor != address(0));
    _delegatorPrivateKey = bound(_delegatorPrivateKey, 1, 100e18);
    address _delegator = vm.addr(_delegatorPrivateKey);
    stdstore.target(address(tokenProxy)).sig("nonces(address)").with_key(_delegator).checked_write(_currentNonce);
    _delegatorBalance = bound(_delegatorBalance, 0, type(uint208).max);
    _currentTimeStamp = bound(_currentTimeStamp, 1, type(uint256).max);
    vm.warp(_currentTimeStamp);
    _deadline = bound(_deadline, 0, _currentTimeStamp - 1);

    _mint(_delegator, _delegatorBalance);

    PartialDelegation[] memory _delegations = _createValidPartialDelegation(0, _delegationSeed);

    bytes32[] memory _payload = new bytes32[](_delegations.length);
    for (uint256 i; i < _delegations.length; i++) {
      _payload[i] = _hash(_delegations[i]);
    }

    bytes32 _message = keccak256(
      abi.encode(
        tokenProxy.PARTIAL_DELEGATION_ON_BEHALF_TYPEHASH(),
        _delegator,
        keccak256(abi.encodePacked(_payload)),
        _currentNonce,
        _deadline
      )
    );

    bytes32 _messageHash = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, _message));
    bytes memory _signature = _sign(_delegatorPrivateKey, _messageHash);
    vm.prank(_actor);
    vm.expectRevert(abi.encodeWithSelector(VotesExpiredSignature.selector, _deadline));
    tokenProxy.delegatePartiallyOnBehalf(_delegator, _delegations, _currentNonce, _deadline, _signature);
  }

  function testFuzz_RevertIf_DelegatesViaInvalidERC712Signature(
    address _actor,
    uint256 _delegatorPrivateKey,
    uint256 _delegationSeed,
    uint256 _delegatorBalance,
    uint256 _currentNonce,
    uint256 _deadline,
    uint256 _randomSeed
  ) public {
    vm.assume(_actor != address(0));
    _delegatorPrivateKey = bound(_delegatorPrivateKey, 1, 100e18);
    address _delegator = vm.addr(_delegatorPrivateKey);
    stdstore.target(address(tokenProxy)).sig("nonces(address)").with_key(_delegator).checked_write(_currentNonce);
    _delegatorBalance = bound(_delegatorBalance, 0, type(uint208).max);
    _deadline = bound(_deadline, 1, type(uint256).max);
    vm.warp(_deadline);
    _deadline = bound(_deadline, 0, block.timestamp - 1);

    _mint(_delegator, _delegatorBalance);

    PartialDelegation[] memory _delegations = _createValidPartialDelegation(0, _delegationSeed);

    bytes32[] memory _payload = new bytes32[](_delegations.length);
    for (uint256 i; i < _delegations.length; i++) {
      _payload[i] = _hash(_delegations[i]);
    }

    bytes32 _message = keccak256(
      abi.encode(
        tokenProxy.PARTIAL_DELEGATION_ON_BEHALF_TYPEHASH(),
        _delegator,
        keccak256(abi.encodePacked(_payload)),
        _currentNonce,
        _deadline
      )
    );

    bytes32 _messageHash = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, _message));

    // Here we use `_randomSeed` as an arbitrary source of randomness to replace a legit parameter
    // with an attack-like one.
    if (_randomSeed % 5 == 0) {
      _delegationSeed = uint256(keccak256(abi.encode(_delegationSeed)));
    } else if (_randomSeed % 5 == 1) {
      _delegator = address(uint160(uint256(keccak256(abi.encode(_delegator)))));
    } else if (_randomSeed % 5 == 2) {
      _currentNonce = uint256(keccak256(abi.encode(_currentNonce)));
    } else if (_randomSeed % 5 == 3) {
      _deadline = uint256(keccak256(abi.encode(_deadline)));
    }

    bytes memory _signature = _sign(_delegatorPrivateKey, _messageHash);
    if (_randomSeed % 5 == 4) {
      _signature = _modifySignature(_signature, _randomSeed);
    }
    vm.prank(_actor);
    vm.expectRevert();
    tokenProxy.delegatePartiallyOnBehalf(_delegator, _delegations, _currentNonce, _deadline, _signature);
  }

  function testFuzz_RevertIf_TheERC1271SignatureIsNotValid(
    address _actor,
    uint256 _delegationSeed,
    uint256 _delegatorBalance,
    uint256 _currentNonce,
    uint256 _deadline,
    bytes memory _signature
  ) public {
    vm.assume(_actor != address(0));
    MockERC1271Signer _erc1271Signer = new MockERC1271Signer();
    _erc1271Signer.setResponse__isValidSignature(false);
    address _delegator = address(_erc1271Signer);
    stdstore.target(address(tokenProxy)).sig("nonces(address)").with_key(address(_delegator)).checked_write(
      _currentNonce
    );
    _delegatorBalance = bound(_delegatorBalance, 0, type(uint208).max);
    _deadline = bound(_deadline, block.timestamp, type(uint256).max);
    _mint(_delegator, _delegatorBalance);

    PartialDelegation[] memory _delegations = _createValidPartialDelegation(0, _delegationSeed);

    bytes32[] memory _payload = new bytes32[](_delegations.length);
    for (uint256 i; i < _delegations.length; i++) {
      _payload[i] = _hash(_delegations[i]);
    }

    vm.prank(_actor);
    vm.expectRevert(InvalidSignature.selector);
    tokenProxy.delegatePartiallyOnBehalf(_delegator, _delegations, _currentNonce, _deadline, _signature);
  }

  function _modifySignature(bytes memory _signature, uint256 _index) internal pure returns (bytes memory) {
    _index = bound(_index, 0, _signature.length - 1);
    // zero out the byte at the given index, or set it to 1 if it's already zero
    if (_signature[_index] == 0) {
      _signature[_index] = bytes1(uint8(1));
    } else {
      _signature[_index] = bytes1(uint8(0));
    }
    return _signature;
  }
}

contract InvalidateNonce is PartialDelegationTest {
  using stdStorage for StdStorage;

  function testFuzz_SucessfullyIncrementsTheNonceOfTheSender(address _caller, uint256 _initialNonce) public {
    vm.assume(_caller != address(0));
    vm.assume(_initialNonce != type(uint256).max);

    stdstore.target(address(tokenProxy)).sig("nonces(address)").with_key(_caller).checked_write(_initialNonce);

    vm.prank(_caller);
    tokenProxy.invalidateNonce();

    uint256 currentNonce = tokenProxy.nonces(_caller);

    assertEq(currentNonce, _initialNonce + 1, "Current nonce is incorrect");
  }

  function testFuzz_IncreasesTheNonceByTwoWhenCalledTwice(address _caller, uint256 _initialNonce) public {
    vm.assume(_caller != address(0));
    _initialNonce = bound(_initialNonce, 0, type(uint256).max - 2);

    stdstore.target(address(tokenProxy)).sig("nonces(address)").with_key(_caller).checked_write(_initialNonce);

    vm.prank(_caller);
    tokenProxy.invalidateNonce();

    vm.prank(_caller);
    tokenProxy.invalidateNonce();

    uint256 currentNonce = tokenProxy.nonces(_caller);

    assertEq(currentNonce, _initialNonce + 2, "Current nonce is incorrect");
  }
}

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
    assertCorrectVotes(_toDelegations, _toExistingBalance + _amount);
    // check that the asset balance successfully updated
    assertEq(tokenProxy.balanceOf(_from), 0, "nonzero `from` balance");
    assertEq(tokenProxy.balanceOf(_to), _toExistingBalance + _amount, "`to` balance mismatch");
    assertEq(tokenProxy.totalSupply(), _toExistingBalance + _amount, "total supply mismatch");
  }

  function testFuzz_EmitsDelegateVotesChangedEventsWhenVotesMoveFromOneDelegateeSetToAnother(
    address _from,
    address _to,
    uint256 _amount,
    uint256 _toExistingBalance
  ) public {
    vm.assume(_from != address(0));
    vm.assume(_to != address(0));
    vm.assume(_from != _to);
    _amount = bound(_amount, 1, type(uint208).max);
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

    _expectEmitDelegateVotesChangedEvents(_amount, _toExistingBalance, _fromDelegations, _toDelegations);
    tokenProxy.transfer(_to, _amount);
    vm.stopPrank();
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
    assertCorrectVotes(_delegations, _existingBalance);
    assertEq(tokenProxy.balanceOf(_holder), _existingBalance, "holder balance is wrong");
    assertEq(tokenProxy.totalSupply(), _existingBalance, "total supply mismatch");
  }
}

contract Permit is PartialDelegationTest {
  error ERC20InsufficientAllowance(address spender, uint256 allowance, uint256 needed);
  error ERC2612ExpiredSignature(uint256 deadline);
  error ERC2612InvalidSigner(address signer, address owner);

  function testFuzz_SuccessfullySetsAllowance(
    uint256 _holderSeed,
    address _receiver,
    uint256 _transferAmount,
    uint256 _existingBalance,
    uint256 _deadline
  ) public {
    _holderSeed = bound(
      _holderSeed,
      1,
      /* private key can't be bigger than secp256k1 curve order */
      115_792_089_237_316_195_423_570_985_008_687_907_852_837_564_279_074_904_382_605_163_141_518_161_494_337 - 1
    );
    address _holder = vm.addr(_holderSeed);
    _deadline = bound(_deadline, block.timestamp, type(uint256).max);
    vm.assume(_holder != address(0));
    vm.assume(_receiver != address(0) && _receiver != _holder);
    _transferAmount = bound(_transferAmount, 0, type(uint208).max);
    _existingBalance = bound(_existingBalance, _transferAmount, type(uint208).max);

    vm.startPrank(_holder);
    tokenProxy.mint(_existingBalance);
    bytes32 _message = keccak256(
      abi.encode(
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
        _holder,
        _receiver,
        _transferAmount,
        tokenProxy.nonces(_holder),
        _deadline
      )
    );
    bytes32 _messageHash = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, _message));
    (uint8 _v, bytes32 _r, bytes32 _s) = vm.sign(_holderSeed, _messageHash);

    tokenProxy.permit(_holder, _receiver, _transferAmount, _deadline, _v, _r, _s);
    vm.stopPrank();

    assertEq(tokenProxy.allowance(_holder, _receiver), _transferAmount);
    vm.prank(_receiver);
    tokenProxy.transferFrom(_holder, _receiver, _transferAmount);
    assertEq(tokenProxy.balanceOf(_receiver), _transferAmount);
  }

  function testFuzz_RevertIf_ERC2612ExpiredSignature(
    uint256 _holderSeed,
    address _receiver,
    uint256 _transferAmount,
    uint256 _existingBalance,
    uint256 _invalidDeadline
  ) public {
    _holderSeed = bound(
      _holderSeed,
      1,
      /* private key can't be bigger than secp256k1 curve order */
      115_792_089_237_316_195_423_570_985_008_687_907_852_837_564_279_074_904_382_605_163_141_518_161_494_337 - 1
    );
    address _holder = vm.addr(_holderSeed);
    _invalidDeadline = bound(_invalidDeadline, 0, block.timestamp - 1);
    vm.assume(_holder != address(0));
    vm.assume(_receiver != address(0) && _receiver != _holder);
    _transferAmount = bound(_transferAmount, 0, type(uint208).max);
    _existingBalance = bound(_existingBalance, _transferAmount, type(uint208).max);

    vm.startPrank(_holder);
    tokenProxy.mint(_existingBalance);
    bytes32 _message = keccak256(
      abi.encode(
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
        _holder,
        _receiver,
        _transferAmount,
        tokenProxy.nonces(_holder),
        _invalidDeadline
      )
    );
    bytes32 _messageHash = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, _message));
    (uint8 _v, bytes32 _r, bytes32 _s) = vm.sign(_holderSeed, _messageHash);

    vm.expectRevert(abi.encodeWithSelector(ERC2612ExpiredSignature.selector, _invalidDeadline));
    tokenProxy.permit(_holder, _receiver, _transferAmount, _invalidDeadline, _v, _r, _s);
    vm.stopPrank();
  }

  function testFuzz_RevertIf_ERC2612InvalidSigner(
    uint256 _holderSeed,
    address _receiver,
    uint256 _transferAmount,
    uint256 _existingBalance,
    uint256 _deadline,
    uint256 _randomSeed
  ) public {
    _holderSeed = bound(
      _holderSeed,
      1,
      /* private key can't be bigger than secp256k1 curve order */
      115_792_089_237_316_195_423_570_985_008_687_907_852_837_564_279_074_904_382_605_163_141_518_161_494_337 - 1
    );
    address _holder = vm.addr(_holderSeed);
    _deadline = bound(_deadline, 0, block.timestamp - 1);
    vm.assume(_holder != address(0));
    vm.assume(_receiver != address(0) && _receiver != _holder);
    _transferAmount = bound(_transferAmount, 0, type(uint208).max);
    _existingBalance = bound(_existingBalance, _transferAmount, type(uint208).max);

    vm.startPrank(_holder);
    tokenProxy.mint(_existingBalance);
    bytes32 _message = keccak256(
      abi.encode(
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
        _holder,
        _receiver,
        _transferAmount,
        tokenProxy.nonces(_holder),
        _deadline
      )
    );
    bytes32 _messageHash = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, _message));

    // Here we use `_randomSeed` as an arbitrary source of randomness to replace a legit parameter
    // with an attack-like one.
    if (_randomSeed % 3 == 0) {
      _receiver = address(uint160(uint256(keccak256(abi.encode(_receiver)))));
    } else if (_randomSeed % 3 == 1) {
      _transferAmount = uint256(keccak256(abi.encode(_transferAmount)));
    }
    (uint8 _v, bytes32 _r, bytes32 _s) = vm.sign(_holderSeed, _messageHash);
    if (_randomSeed % 3 == 2) {
      (_v, _r, _s) = vm.sign(uint256(keccak256(abi.encode(_holderSeed))), _messageHash);
    }

    vm.expectRevert(abi.encodeWithSelector(ERC2612ExpiredSignature.selector, _deadline));
    tokenProxy.permit(_holder, _receiver, _transferAmount, _deadline, _v, _r, _s);
    vm.stopPrank();
  }
}

contract GetPastVotes is PartialDelegationTest {
  function testFuzz_ReturnsCorrectVotes(address _actor, uint256 _amount, uint48 _blocksAhead, uint256 _secondMint)
    public
  {
    vm.assume(_actor != address(0));
    _amount = bound(_amount, 0, type(uint208).max);
    _secondMint = bound(_secondMint, 0, type(uint208).max - _amount);
    uint256 _blockNo = vm.getBlockNumber();
    _blocksAhead = uint48(bound(_blocksAhead, 1, type(uint48).max - _blockNo));
    vm.startPrank(_actor);
    tokenProxy.mint(_amount);
    vm.stopPrank();
    PartialDelegation[] memory _delegations = _createValidPartialDelegation(0, uint256(keccak256(abi.encode(_actor))));
    vm.startPrank(_actor);
    tokenProxy.delegate(_delegations);
    vm.stopPrank();
    vm.roll(_blockNo + _blocksAhead);
    vm.startPrank(_actor);
    // do a second mint that will increase delegatees' votes
    tokenProxy.mint(_secondMint);
    vm.stopPrank();
    assertCorrectPastVotes(_delegations, _amount, _blockNo);
    assertCorrectVotes(_delegations, _amount + _secondMint);
  }
}

contract GetPastTotalSupply is PartialDelegationTest {
  function testFuzz_ReturnsCorrectPastTotalSupply(
    address _actor,
    uint256 _amount,
    uint48 _blocksAhead,
    uint256 _secondMint
  ) public {
    vm.assume(_actor != address(0));
    _amount = bound(_amount, 0, type(uint208).max);
    _secondMint = bound(_secondMint, 0, type(uint208).max - _amount);
    uint256 _blockNo = vm.getBlockNumber();
    _blocksAhead = uint48(bound(_blocksAhead, 1, type(uint48).max - _blockNo));
    vm.startPrank(_actor);
    tokenProxy.mint(_amount);
    vm.roll(_blockNo + _blocksAhead);
    // do a second mint that will increase total supply
    tokenProxy.mint(_secondMint);
    vm.stopPrank();
    assertEq(tokenProxy.totalSupply(), _amount + _secondMint);
    assertEq(tokenProxy.getPastTotalSupply(_blockNo), _amount);
  }
}

// This contract strengthens our confidence in our test helper, `_expectEmitDelegateChangedEvents`
contract ExpectEmitDelegateChangedEvents is PartialDelegationTest {
  function test_EmitsWhenFromNoDelegateeToANewDelegateeIsAdded() public {
    address _actor = address(this);
    PartialDelegation[] memory _oldDelegations = new PartialDelegation[](0);
    PartialDelegation[] memory _newDelegations = new PartialDelegation[](1);
    _newDelegations[0] = PartialDelegation({_delegatee: address(0x1), _numerator: 5000});

    vm.recordLogs();
    _expectEmitDelegateChangedEvents(_actor, _oldDelegations, _newDelegations);
    uint256 _logLength = vm.getRecordedLogs().length;

    emit DelegateChanged(_actor, address(0x1), 5000);
    assertEq(_logLength, 1);
  }

  function test_EmitsWhenBothDelegationsHaveTheSameDelegateeButTheNumeratorIsDifferent() public {
    address _actor = address(this);
    PartialDelegation[] memory _oldDelegations = new PartialDelegation[](1);
    _oldDelegations[0] = PartialDelegation({_delegatee: address(0x1), _numerator: 10_000});
    PartialDelegation[] memory _newDelegations = new PartialDelegation[](1);
    _newDelegations[0] = PartialDelegation({_delegatee: address(0x1), _numerator: 5000});

    vm.recordLogs();
    _expectEmitDelegateChangedEvents(_actor, _oldDelegations, _newDelegations);
    uint256 _logLength = vm.getRecordedLogs().length;

    emit DelegateChanged(_actor, address(0x1), 5000);
    assertEq(_logLength, 1);
  }

  function test_EmitsWhenOldDelegateeComesBeforeTheNewDelegatee() public {
    address _actor = address(this);
    PartialDelegation[] memory _oldDelegations = new PartialDelegation[](1);
    _oldDelegations[0] = PartialDelegation({_delegatee: address(0x1), _numerator: 10_000});
    PartialDelegation[] memory _newDelegations = new PartialDelegation[](2);
    _newDelegations[0] = PartialDelegation({_delegatee: address(0x1), _numerator: 5000});
    _newDelegations[1] = PartialDelegation({_delegatee: address(0x2), _numerator: 5000});

    vm.recordLogs();
    _expectEmitDelegateChangedEvents(_actor, _oldDelegations, _newDelegations);
    uint256 _logLength = vm.getRecordedLogs().length;

    emit DelegateChanged(_actor, address(0x1), 5000);
    emit DelegateChanged(_actor, address(0x2), 5000);
    assertEq(_logLength, 2);
  }

  function test_EmitsWhenNewDelegateeComesBeforeTheOldDelegatee() public {
    address _actor = address(this);
    PartialDelegation[] memory _oldDelegations = new PartialDelegation[](1);
    _oldDelegations[0] = PartialDelegation({_delegatee: address(0x2), _numerator: 10_000});
    PartialDelegation[] memory _newDelegations = new PartialDelegation[](2);
    _newDelegations[0] = PartialDelegation({_delegatee: address(0x1), _numerator: 5000});
    _newDelegations[1] = PartialDelegation({_delegatee: address(0x2), _numerator: 5000});

    vm.recordLogs();
    _expectEmitDelegateChangedEvents(_actor, _oldDelegations, _newDelegations);
    uint256 _logLength = vm.getRecordedLogs().length;

    emit DelegateChanged(_actor, address(0x1), 5000);
    emit DelegateChanged(_actor, address(0x2), 5000);
    assertEq(_logLength, 2);
  }

  function test_CrazyCase1() public {
    address _actor = address(this);
    PartialDelegation[] memory _oldDelegations = new PartialDelegation[](8);
    _oldDelegations[0] = PartialDelegation({_delegatee: address(0x1), _numerator: 5});
    _oldDelegations[1] = PartialDelegation({_delegatee: address(0x2), _numerator: 7});
    _oldDelegations[2] = PartialDelegation({_delegatee: address(0x3), _numerator: 9});
    _oldDelegations[3] = PartialDelegation({_delegatee: address(0x4), _numerator: 11});
    _oldDelegations[4] = PartialDelegation({_delegatee: address(0xA), _numerator: 13});
    _oldDelegations[5] = PartialDelegation({_delegatee: address(0xB), _numerator: 15});
    _oldDelegations[6] = PartialDelegation({_delegatee: address(0xC), _numerator: 17});
    _oldDelegations[7] = PartialDelegation({_delegatee: address(0xD), _numerator: 19});

    PartialDelegation[] memory _newDelegations = new PartialDelegation[](7);
    // prepend
    _newDelegations[0] = PartialDelegation({_delegatee: address(0x0), _numerator: 5});
    // leave 0x1 the same
    _newDelegations[1] = PartialDelegation({_delegatee: address(0x1), _numerator: 5});
    // change numerator for 0x2
    _newDelegations[2] = PartialDelegation({_delegatee: address(0x2), _numerator: 19});
    // remove 0x3
    // remove 0x4, add 0x9
    _newDelegations[3] = PartialDelegation({_delegatee: address(0x9), _numerator: 1150});
    // keep 0xA the same
    _newDelegations[4] = PartialDelegation({_delegatee: address(0xA), _numerator: 13});
    // remove 0xB
    // keep 0xC the same
    // change 0xD numerator
    _newDelegations[5] = PartialDelegation({_delegatee: address(0xD), _numerator: 170});
    // add 0xE
    _newDelegations[6] = PartialDelegation({_delegatee: address(0xE), _numerator: 190});

    vm.recordLogs();
    _expectEmitDelegateChangedEvents(_actor, _oldDelegations, _newDelegations);
    uint256 _logLength = vm.getRecordedLogs().length;

    // Source of truth events: The events that we want the expect helper to expect, given the delegation changes.
    // 0x0 emitted because new delegate
    emit DelegateChanged(_actor, address(0x0), 5);
    // skip 0x1 as no change
    // 0x2 emitted because numerator change
    emit DelegateChanged(_actor, address(0x2), 19);
    // 0x3 emitted because removed
    emit DelegateChanged(_actor, address(0x3), 0);
    // 0x4 emitted because removed
    emit DelegateChanged(_actor, address(0x4), 0);
    // 0x9 emitted because added
    emit DelegateChanged(_actor, address(0x9), 1150);
    // 0xA skipped, no change
    // 0xB emitted because removed
    emit DelegateChanged(_actor, address(0xB), 0);
    // 0xC emitted because removed
    emit DelegateChanged(_actor, address(0xC), 0);
    // 0xD emitted because numerator change
    emit DelegateChanged(_actor, address(0xD), 170);
    // 0xE emitted because added
    emit DelegateChanged(_actor, address(0xE), 190);
    uint256 _expectedLength = vm.getRecordedLogs().length;
    assertEq(_logLength, _expectedLength);
  }
}

// This contract strengthens our confidence in our test helper, `_expectEmitDelegateVotesChangedEvents`
contract ExpectEmitDelegateVotesChangedEvents is PartialDelegationTest {
  /// An Ethereum log. Returned by `getRecordedLogs`.

  function test_EmitsWhenFromNoDelegateeToANewDelegateeIsAdded() public {
    PartialDelegation[] memory _oldDelegations = new PartialDelegation[](0);
    PartialDelegation[] memory _newDelegations = new PartialDelegation[](1);
    _newDelegations[0] = PartialDelegation({_delegatee: address(0x1), _numerator: 10_000});

    vm.recordLogs();
    _expectEmitDelegateVotesChangedEvents(100, _oldDelegations, _newDelegations);
    Vm.Log[] memory entries = vm.getRecordedLogs();
    uint256 _logLength = entries.length;

    // Initialized(18_446_744_073_709_551_615) from FakeERC20VotesPartialDelegationUpgradeable utils = new
    // FakeERC20VotesPartialDelegationUpgradeable();
    assertEq(entries[0].topics[0], keccak256("Initialized(uint64)"));
    emit DelegateVotesChanged(address(0x1), 0, 100);
    assertEq(_logLength, 2);
  }

  function test_EmitsWhenBothDelegationsHaveTheSameDelegatee() public {
    PartialDelegation[] memory _oldDelegations = new PartialDelegation[](1);
    _oldDelegations[0] = PartialDelegation({_delegatee: address(0x1), _numerator: 10_000});
    PartialDelegation[] memory _newDelegations = new PartialDelegation[](1);
    _newDelegations[0] = PartialDelegation({_delegatee: address(0x1), _numerator: 10_000});

    vm.recordLogs();
    _expectEmitDelegateVotesChangedEvents(100, _oldDelegations, _newDelegations);
    Vm.Log[] memory entries = vm.getRecordedLogs();
    uint256 _logLength = entries.length;

    assertEq(entries[0].topics[0], keccak256("Initialized(uint64)"));
    assertEq(_logLength, 1);
  }

  function test_EmitsWhenBothDelegationsHaveTheSameDelegateeButDifferentNumerators() public {
    PartialDelegation[] memory _oldDelegations = new PartialDelegation[](1);
    _oldDelegations[0] = PartialDelegation({_delegatee: address(0x1), _numerator: 10_000});
    PartialDelegation[] memory _newDelegations = new PartialDelegation[](1);
    _newDelegations[0] = PartialDelegation({_delegatee: address(0x1), _numerator: 5000});

    vm.recordLogs();
    _expectEmitDelegateVotesChangedEvents(100, _oldDelegations, _newDelegations);
    Vm.Log[] memory entries = vm.getRecordedLogs();
    uint256 _logLength = entries.length;

    assertEq(entries[0].topics[0], keccak256("Initialized(uint64)"));
    emit DelegateVotesChanged(address(0x1), 100, 50);
    assertEq(_logLength, 2);
  }

  function test_EmitsWhenOldDelegateeComesBeforeTheNewDelegatee() public {
    PartialDelegation[] memory _oldDelegations = new PartialDelegation[](1);
    _oldDelegations[0] = PartialDelegation({_delegatee: address(0x1), _numerator: 10_000});
    PartialDelegation[] memory _newDelegations = new PartialDelegation[](2);
    _newDelegations[0] = PartialDelegation({_delegatee: address(0x1), _numerator: 5000});
    _newDelegations[1] = PartialDelegation({_delegatee: address(0x2), _numerator: 5000});

    vm.recordLogs();
    _expectEmitDelegateVotesChangedEvents(100, _oldDelegations, _newDelegations);

    Vm.Log[] memory entries = vm.getRecordedLogs();
    uint256 _logLength = entries.length;

    assertEq(entries[0].topics[0], keccak256("Initialized(uint64)"));
    emit DelegateVotesChanged(address(0x1), 100, 50);
    emit DelegateVotesChanged(address(0x2), 0, 50);
    assertEq(_logLength, 3);
  }

  function test_EmitsWhenNewDelegateeComesBeforeTheOldDelegateeReplacingTheOldDelegatee() public {
    PartialDelegation[] memory _oldDelegations = new PartialDelegation[](1);
    _oldDelegations[0] = PartialDelegation({_delegatee: address(0x2), _numerator: 10_000});
    PartialDelegation[] memory _newDelegations = new PartialDelegation[](1);
    _newDelegations[0] = PartialDelegation({_delegatee: address(0x1), _numerator: 10_000});

    vm.recordLogs();
    _expectEmitDelegateVotesChangedEvents(100, _oldDelegations, _newDelegations);

    Vm.Log[] memory entries = vm.getRecordedLogs();
    uint256 _logLength = entries.length;

    assertEq(entries[0].topics[0], keccak256("Initialized(uint64)"));
    emit DelegateVotesChanged(address(0x1), 0, 100);
    emit DelegateVotesChanged(address(0x2), 100, 0);
    assertEq(_logLength, 3);
  }

  function test_EmitsWhenNewDelegateeComesBeforeTheOldDelegateeIncludingThePreviousDelegatee() public {
    PartialDelegation[] memory _oldDelegations = new PartialDelegation[](1);
    _oldDelegations[0] = PartialDelegation({_delegatee: address(0x2), _numerator: 10_000});
    PartialDelegation[] memory _newDelegations = new PartialDelegation[](2);
    _newDelegations[0] = PartialDelegation({_delegatee: address(0x1), _numerator: 5000});
    _newDelegations[1] = PartialDelegation({_delegatee: address(0x2), _numerator: 5000});

    vm.recordLogs();
    _expectEmitDelegateVotesChangedEvents(100, _oldDelegations, _newDelegations);

    Vm.Log[] memory entries = vm.getRecordedLogs();
    uint256 _logLength = entries.length;

    assertEq(entries[0].topics[0], keccak256("Initialized(uint64)"));
    emit DelegateVotesChanged(address(0x1), 0, 50);
    emit DelegateVotesChanged(address(0x2), 100, 50);
    assertEq(_logLength, 3);
  }
}

// This contract strengthens our confidence in our test helper, `_expectEmitDelegateChangedEvents` (the 4 param version)
contract ExpectEmitDelegateVotesChangedEventsDuringTransfer is PartialDelegationTest {
  function test_EmitsWhenTransferringTokensFromAnAddressWithNoDelegationsToAnAddressWithNoDelegations() public {
    address from = address(0x10);
    address to = address(0x20);
    PartialDelegation[] memory _oldDelegations = new PartialDelegation[](0);
    PartialDelegation[] memory _newDelegations = new PartialDelegation[](0);

    vm.prank(from);
    tokenProxy.mint(100);

    vm.prank(to);
    tokenProxy.mint(100);

    vm.recordLogs();
    _expectEmitDelegateVotesChangedEvents(100, 100, _oldDelegations, _newDelegations);
    Vm.Log[] memory entries = vm.getRecordedLogs();
    uint256 _logLength = entries.length;

    assertEq(_logLength, 0);
  }

  function test_EmitsWhenTransferringTokensFromAnAddressWithSingleDelegateeToAnAddressWithNoDelegations() public {
    address from = address(0x10);
    address to = address(0x20);
    PartialDelegation[] memory _oldDelegations = new PartialDelegation[](1);
    _oldDelegations[0] = PartialDelegation({_delegatee: address(0x1), _numerator: 10_000});
    PartialDelegation[] memory _newDelegations = new PartialDelegation[](0);

    vm.startPrank(from);
    tokenProxy.mint(100);
    tokenProxy.delegate(_oldDelegations);
    vm.stopPrank();

    vm.prank(to);
    tokenProxy.mint(100);

    vm.recordLogs();
    _expectEmitDelegateVotesChangedEvents(100, 100, _oldDelegations, _newDelegations);
    Vm.Log[] memory entries = vm.getRecordedLogs();
    uint256 _logLength = entries.length;

    emit DelegateVotesChanged(address(0x1), 100, 0);
    assertEq(_logLength, 1);
  }

  function test_EmitsWhenTransferringTokensFromAnAddressWithSingleDelegateeToAnAddressWithASingleDelegatee() public {
    address from = address(0x10);
    address to = address(0x20);
    PartialDelegation[] memory _oldDelegations = new PartialDelegation[](1);
    _oldDelegations[0] = PartialDelegation({_delegatee: address(0x1), _numerator: 10_000});
    PartialDelegation[] memory _newDelegations = new PartialDelegation[](1);
    _newDelegations[0] = PartialDelegation({_delegatee: address(0x2), _numerator: 10_000});

    vm.startPrank(from);
    tokenProxy.mint(100);
    tokenProxy.delegate(_oldDelegations);
    vm.stopPrank();

    vm.startPrank(to);
    tokenProxy.mint(100);
    tokenProxy.delegate(_newDelegations);
    vm.stopPrank();

    vm.recordLogs();
    _expectEmitDelegateVotesChangedEvents(100, 100, _oldDelegations, _newDelegations);
    Vm.Log[] memory entries = vm.getRecordedLogs();
    uint256 _logLength = entries.length;

    emit DelegateVotesChanged(address(0x1), 100, 0);
    emit DelegateVotesChanged(address(0x2), 100, 200);
    assertEq(_logLength, 2);
  }

  function test_EmitsWhenTransferringTokensFromAnAddressWithNoDelegationsToAnAddressWithASingleDelegatee() public {
    address from = address(0x10);
    address to = address(0x20);
    PartialDelegation[] memory _oldDelegations = new PartialDelegation[](0);
    PartialDelegation[] memory _newDelegations = new PartialDelegation[](1);
    _newDelegations[0] = PartialDelegation({_delegatee: address(0x2), _numerator: 10_000});

    vm.prank(from);
    tokenProxy.mint(100);

    vm.startPrank(to);
    tokenProxy.mint(100);
    tokenProxy.delegate(_newDelegations);
    vm.stopPrank();

    vm.recordLogs();
    _expectEmitDelegateVotesChangedEvents(100, 100, _oldDelegations, _newDelegations);
    Vm.Log[] memory entries = vm.getRecordedLogs();
    uint256 _logLength = entries.length;

    emit DelegateVotesChanged(address(0x2), 100, 200);
    assertEq(_logLength, 1);
  }

  function test_EmitsWhenTransferringTokensFromAnAddressWithNoDelegationsToAnAddressWithMultipleDelegatees() public {
    address from = address(0x10);
    address to = address(0x20);
    PartialDelegation[] memory _oldDelegations = new PartialDelegation[](0);
    PartialDelegation[] memory _newDelegations = new PartialDelegation[](2);
    _newDelegations[0] = PartialDelegation({_delegatee: address(0x2), _numerator: 5000});
    _newDelegations[1] = PartialDelegation({_delegatee: address(0x3), _numerator: 5000});

    vm.prank(from);
    tokenProxy.mint(100);

    vm.startPrank(to);
    tokenProxy.mint(100);
    tokenProxy.delegate(_newDelegations);
    vm.stopPrank();

    vm.recordLogs();
    _expectEmitDelegateVotesChangedEvents(100, 100, _oldDelegations, _newDelegations);
    Vm.Log[] memory entries = vm.getRecordedLogs();
    uint256 _logLength = entries.length;

    emit DelegateVotesChanged(address(0x2), 50, 100);
    emit DelegateVotesChanged(address(0x3), 50, 100);
    assertEq(_logLength, 2);
  }

  function test_EmitsWhenTransferringTokensFromAnAddressWithMultipleDelegateesToAnAddressWithMultipleDelegatees()
    public
  {
    address from = address(0x10);
    address to = address(0x20);
    PartialDelegation[] memory _oldDelegations = new PartialDelegation[](2);
    _oldDelegations[0] = PartialDelegation({_delegatee: address(0x1), _numerator: 5000});
    _oldDelegations[1] = PartialDelegation({_delegatee: address(0x2), _numerator: 5000});

    PartialDelegation[] memory _newDelegations = new PartialDelegation[](2);
    _newDelegations[0] = PartialDelegation({_delegatee: address(0x3), _numerator: 5000});
    _newDelegations[1] = PartialDelegation({_delegatee: address(0x4), _numerator: 5000});

    vm.startPrank(from);
    tokenProxy.mint(100);
    tokenProxy.delegate(_oldDelegations);
    vm.stopPrank();

    vm.startPrank(to);
    tokenProxy.mint(100);
    tokenProxy.delegate(_newDelegations);
    vm.stopPrank();

    vm.recordLogs();
    _expectEmitDelegateVotesChangedEvents(100, 100, _oldDelegations, _newDelegations);
    Vm.Log[] memory entries = vm.getRecordedLogs();
    uint256 _logLength = entries.length;

    emit DelegateVotesChanged(address(0x1), 50, 0);
    emit DelegateVotesChanged(address(0x2), 50, 0);
    emit DelegateVotesChanged(address(0x3), 50, 100);
    emit DelegateVotesChanged(address(0x4), 50, 100);
    assertEq(_logLength, 4);
  }
}
