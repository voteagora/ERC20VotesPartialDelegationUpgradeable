// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {FakeERC20VotesPartialDelegationUpgradeable} from "../fakes/FakeERC20VotesPartialDelegationUpgradeable.sol";
import {PartialDelegation, DelegationAdjustment} from "../../src/IVotesPartialDelegation.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract TestHarness is Test {
  FakeERC20VotesPartialDelegationUpgradeable public tokenImpl;
  FakeERC20VotesPartialDelegationUpgradeable public tokenProxy;

  /// @dev Emitted when an account changes their delegate.
  event DelegateChanged(address indexed delegator, address indexed delegatee, uint96 numerator);
  /// @dev Emitted when a token transfer or delegate change results in changes to a delegate's number of voting units.
  event DelegateVotesChanged(address indexed delegate, uint256 previousVotes, uint256 newVotes);

  function setUp() public virtual {
    tokenImpl = new FakeERC20VotesPartialDelegationUpgradeable();
    tokenProxy = FakeERC20VotesPartialDelegationUpgradeable(address(new ERC1967Proxy(address(tokenImpl), "")));
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
      uint256 _expectedVoteWeight = _votes[i]._amount;
      assertEq(
        tokenProxy.getVotes(_delegations[i]._delegatee), _expectedVoteWeight, "incorrect vote weight for delegate"
      );
      _totalWeight += _votes[i]._amount;
    }
    assertLe(_totalWeight, _amount, "incorrect total weight");
  }

  function _mint(address _to, uint256 _amount) internal {
    vm.prank(_to);
    tokenProxy.mint(_amount);
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
      uint96 _numerator = uint96(
        bound(
          uint256(keccak256(abi.encode(_seed + i))) % tokenProxy.DENOMINATOR(), // initial value of the numerator
          1,
          tokenProxy.DENOMINATOR() - _totalNumerator - (_n - i) // ensure that there is enough numerator left for the
            // remaining delegations
        )
      );
      delegations[i] = PartialDelegation(address(uint160(uint160(vm.addr(_seed)) + i)), _numerator);
      _totalNumerator += _numerator;
    }
    return delegations;
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
    PartialDelegation[] memory _fromPartialDelegations,
    PartialDelegation[] memory _toPartialDelegations
  ) internal {
    FakeERC20VotesPartialDelegationUpgradeable utils = new FakeERC20VotesPartialDelegationUpgradeable();
    DelegationAdjustment[] memory _initialVotes =
      utils.exposed_calculateWeightDistribution(_fromPartialDelegations, _amount);
    DelegationAdjustment[] memory _votes = utils.exposed_calculateWeightDistribution(_toPartialDelegations, _amount);

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
          if (_votes[j]._amount != 0 || _initialVotes[j]._amount != 0) {
            vm.expectEmit();
            emit DelegateVotesChanged(
              _fromPartialDelegations[i]._delegatee, _initialVotes[j]._amount, _votes[j]._amount
            );
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
        if (_initialVotes[i]._amount != 0) {
          vm.expectEmit();
          emit DelegateVotesChanged(_fromPartialDelegations[i]._delegatee, _initialVotes[i]._amount, 0);
        }
        i++;
        // If new delegatee comes before the old delegatee OR old delegatees have been exhausted
      } else {
        if (_votes[j]._amount != 0) {
          vm.expectEmit();
          emit DelegateVotesChanged(_toPartialDelegations[j]._delegatee, 0, _votes[j]._amount);
        }
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
