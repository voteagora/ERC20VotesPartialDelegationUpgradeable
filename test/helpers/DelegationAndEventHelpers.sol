// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC20VotesPartialDelegationUpgradeable} from "src/ERC20VotesPartialDelegationUpgradeable.sol";
import {FakeERC20VotesPartialDelegationUpgradeable} from "test/fakes/FakeERC20VotesPartialDelegationUpgradeable.sol";
import {PartialDelegation, DelegationAdjustment} from "src/IVotesPartialDelegation.sol";

contract DelegationAndEventHelpers is Test {
  ERC20VotesPartialDelegationUpgradeable token;

  /// @dev Emitted when an account changes their delegate.
  event DelegateChanged(
    address indexed delegator, PartialDelegation[] oldDelegatees, PartialDelegation[] newDelegatees
  );
  /// @dev Emitted when a token transfer or delegate change results in changes to a delegate's number of voting units.
  event DelegateVotesChanged(address indexed delegate, uint256 previousVotes, uint256 newVotes);

  event VotableSupplyChanged(uint256 oldVotableSupply, uint256 newVotableSupply);

  function initialize(address _token) public virtual {
    token = ERC20VotesPartialDelegationUpgradeable(_token);
  }

  /// @dev
  function _createValidPartialDelegation(uint256 _n, uint256 _seed) internal view returns (PartialDelegation[] memory) {
    _seed = bound(
      _seed,
      1,
      /* private key can't be bigger than secp256k1 curve order */
      115_792_089_237_316_195_423_570_985_008_687_907_852_837_564_279_074_904_382_605_163_141_518_161_494_337 - 1
    );
    _n = _n != 0 ? _n : (_seed % token.MAX_PARTIAL_DELEGATIONS()) + 1;
    PartialDelegation[] memory delegations = new PartialDelegation[](_n);
    uint96 _totalNumerator;
    for (uint256 i = 0; i < _n; i++) {
      uint96 _numerator = uint96(
        bound(
          uint256(keccak256(abi.encode(_seed + i))) % token.DENOMINATOR(), // initial value of the numerator
          1,
          token.DENOMINATOR() - _totalNumerator - (_n - i) // ensure that there is enough numerator left for the
            // remaining delegations
        )
      );
      delegations[i] = PartialDelegation(address(uint160(uint160(vm.addr(_seed)) + i)), _numerator);
      _totalNumerator += _numerator;
    }
    return delegations;
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
          if (_votes[j]._amount != 0 || _initialVotes[i]._amount != 0) {
            vm.expectEmit();
            emit DelegateVotesChanged(
              _fromPartialDelegations[i]._delegatee, _initialVotes[i]._amount, _votes[j]._amount
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
}
