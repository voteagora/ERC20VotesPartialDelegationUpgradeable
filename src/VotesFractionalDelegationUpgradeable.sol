// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts (last updated v5.0.0) (governance/utils/Votes.sol)
pragma solidity ^0.8.20;

import {IERC5805Modified} from "src/IERC5805Modified.sol";
import {ContextUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";
import {NoncesUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/NoncesUpgradeable.sol";
import {EIP712Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import {Checkpoints} from "@openzeppelin/contracts/utils/structs/Checkpoints.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Time} from "@openzeppelin/contracts/utils/types/Time.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

/**
 * @dev This is a base abstract contract that tracks voting units, which are a measure of voting power that can be
 * transferred, and provides a system of vote delegation, where an account can delegate its voting units to a sort of
 * "representative" that will pool delegated voting units from different accounts and can then use it to vote in
 * decisions. In fact, voting units _must_ be delegated in order to count as actual votes, and an account has to
 * delegate those votes to itself if it wishes to participate in decisions and does not have a trusted representative.
 *
 * This contract is often combined with a token contract such that voting units correspond to token units. For an
 * example, see {ERC721Votes}.
 *
 * The full history of delegate votes is tracked on-chain so that governance protocols can consider votes as distributed
 * at a particular block number to protect against flash loans and double voting. The opt-in delegate system makes the
 * cost of this history tracking optional.
 *
 * When using this module the derived contract must implement {_getVotingUnits} (for example, make it return
 * {ERC721-balanceOf}), and can use {_transferVotingUnits} to track a change in the distribution of those units (in the
 * previous example, it would be included in {ERC721-_update}).
 */
abstract contract VotesFractionalDelegationUpgradeable is
  Initializable,
  ContextUpgradeable,
  EIP712Upgradeable,
  NoncesUpgradeable,
  IERC5805Modified
{
  using Checkpoints for Checkpoints.Trace208;

  bytes32 private constant FRACTIONAL_DELEGATION_TYPEHASH =
    keccak256("FractionalDelegation(FractionalDelegation[] delegations,uint256 nonce,uint256 expiry)");
  uint256 constant MAX_FRACTIONAL_DELEGATIONS = 10;
  uint8 constant DENOMINATOR = 255;

  struct FractionalDelegation {
    address _delegatee;
    uint8 _numerator;
  }

  struct DelegationAdjustment {
    address _delegatee;
    uint208 _amount;
    bool _isAddition;
  }

  /// @custom:storage-location erc7201:openzeppelin.storage.Votes
  struct VotesFractionalDelegationStorage {
    mapping(address account => FractionalDelegation[]) _delegatees;
    mapping(address delegatee => Checkpoints.Trace208) _delegateCheckpoints;
    Checkpoints.Trace208 _totalCheckpoints;
  }

  // keccak256(abi.encode(uint256(keccak256("openzeppelin.storage.VotesFractionalDelegation")) - 1)) &
  // ~bytes32(uint256(0xff))
  bytes32 private constant VotesFractionalDelegationStorageLocation =
    0x50e95a9f47aa972f88438aa6b410b8e63f6c302a5e5a609a3e35a277ef79ed00;

  function _getVotesFractionalDelegationStorage() private pure returns (VotesFractionalDelegationStorage storage $) {
    assembly {
      $.slot := VotesFractionalDelegationStorageLocation
    }
  }

  /**
   * @dev The clock was incorrectly modified.
   */
  error ERC6372InconsistentClock();

  /**
   * @dev Lookup to future votes is not available.
   */
  error ERC5805FutureLookup(uint256 timepoint, uint48 clock);

  function __VotesFractionalDelegation_init() internal onlyInitializing {}

  function __VotesFractionalDelegation_init_unchained() internal onlyInitializing {}
  /**
   * @dev Clock used for flagging checkpoints. Can be overridden to implement timestamp based
   * checkpoints (and voting), in which case {CLOCK_MODE} should be overridden as well to match.
   */

  function clock() public view virtual returns (uint48) {
    return Time.blockNumber();
  }

  /**
   * @dev Machine-readable description of the clock as specified in EIP-6372.
   */
  // solhint-disable-next-line func-name-mixedcase
  function CLOCK_MODE() public view virtual returns (string memory) {
    // Check that the clock was not modified
    if (clock() != Time.blockNumber()) {
      revert ERC6372InconsistentClock();
    }
    return "mode=blocknumber&from=default";
  }

  /**
   * @dev Returns the current amount of votes that `account` has.
   */
  function getVotes(address account) public view virtual returns (uint256) {
    VotesFractionalDelegationStorage storage $ = _getVotesFractionalDelegationStorage();
    return $._delegateCheckpoints[account].latest();
  }

  /**
   * @dev Returns the amount of votes that `account` had at a specific moment in the past. If the `clock()` is
   * configured to use block numbers, this will return the value at the end of the corresponding block.
   *
   * Requirements:
   *
   * - `timepoint` must be in the past. If operating using block numbers, the block must be already mined.
   */
  function getPastVotes(address account, uint256 timepoint) public view virtual returns (uint256) {
    VotesFractionalDelegationStorage storage $ = _getVotesFractionalDelegationStorage();
    uint48 currentTimepoint = clock();
    if (timepoint >= currentTimepoint) {
      revert ERC5805FutureLookup(timepoint, currentTimepoint);
    }
    return $._delegateCheckpoints[account].upperLookupRecent(SafeCast.toUint48(timepoint));
  }

  /**
   * @dev Returns the total supply of votes available at a specific moment in the past. If the `clock()` is
   * configured to use block numbers, this will return the value at the end of the corresponding block.
   *
   * NOTE: This value is the sum of all available votes, which is not necessarily the sum of all delegated votes.
   * Votes that have not been delegated are still part of total supply, even though they would not participate in a
   * vote.
   *
   * Requirements:
   *
   * - `timepoint` must be in the past. If operating using block numbers, the block must be already mined.
   */
  function getPastTotalSupply(uint256 timepoint) public view virtual returns (uint256) {
    VotesFractionalDelegationStorage storage $ = _getVotesFractionalDelegationStorage();
    uint48 currentTimepoint = clock();
    if (timepoint >= currentTimepoint) {
      revert ERC5805FutureLookup(timepoint, currentTimepoint);
    }
    return $._totalCheckpoints.upperLookupRecent(SafeCast.toUint48(timepoint));
  }

  /**
   * @dev Returns the current total supply of votes.
   */
  function _getTotalSupply() internal view virtual returns (uint256) {
    VotesFractionalDelegationStorage storage $ = _getVotesFractionalDelegationStorage();
    return $._totalCheckpoints.latest();
  }

  /**
   * @dev Returns the delegate that `account` has chosen.
   */
  function delegates(address account) public view virtual returns (FractionalDelegation[] memory) {
    VotesFractionalDelegationStorage storage $ = _getVotesFractionalDelegationStorage();
    return $._delegatees[account];
  }

  // TODO: this no longer makes sense. Are we no longer adhering to ERC5805 or IVotes, then?
  //   function delegates(address account) external view override returns (address) {
  //     return account;
  //   }

  /**
   * @dev Delegates votes from the sender to `delegatee`.
   */
  function delegate(FractionalDelegation[] calldata _fractionalDelegations) public virtual {
    address account = _msgSender();
    _delegate(account, _fractionalDelegations);
  }

  /**
   * @dev Delegates votes from signer to `delegatee`.
   */
  function delegateBySig(
    FractionalDelegation[] memory _fractionalDelegations,
    uint256 nonce,
    uint256 expiry,
    uint8 v,
    bytes32 r,
    bytes32 s
  ) public virtual {
    if (block.timestamp > expiry) {
      revert VotesExpiredSignature(expiry);
    }
    address signer = ECDSA.recover(
      _hashTypedDataV4(keccak256(abi.encode(FRACTIONAL_DELEGATION_TYPEHASH, _fractionalDelegations, nonce, expiry))),
      v,
      r,
      s
    );
    _useCheckedNonce(signer, nonce);
    _delegate(signer, _fractionalDelegations);
  }

  /**
   * @dev Delegate all of `account`'s voting units to delegates specified in `fractionalDelegations`.
   *
   * Emits events {IVotes-DelegateChanged} and {IVotes-DelegateVotesChanged}.
   */
  function _delegate(address _account, FractionalDelegation[] memory _fractionalDelegations) internal virtual {
    VotesFractionalDelegationStorage storage $ = _getVotesFractionalDelegationStorage();
    FractionalDelegation[] memory _oldDelegations = delegates(_account);
    DelegationAdjustment[] memory _old = _calculateWeightDistribution(_oldDelegations, _getVotingUnits(_account), false);
    DelegationAdjustment[] memory _new =
      _calculateWeightDistribution(_fractionalDelegations, _getVotingUnits(_account), true);
    // (optional) prune and sum _old and _new
    _adjustDelegateVotes(_old);
    _adjustDelegateVotes(_new);

    // All this code is to update the new delegatees
    uint256 _oldDelegateLength = _oldDelegations.length;
    for (uint256 i = 0; i < _fractionalDelegations.length; i++) {
      if (i < _oldDelegateLength) {
        $._delegatees[_account][i] = _fractionalDelegations[i];
      } else {
        $._delegatees[_account].push(_fractionalDelegations[i]);
      }
      if (i == _oldDelegateLength) {
        $._delegatees[_account].pop();
      }
    }
    if (_oldDelegateLength > _fractionalDelegations.length) {
      for (uint256 i = _fractionalDelegations.length; i < _oldDelegateLength; i++) {
        $._delegatees[_account].pop();
      }
    }

    // TODO: emit event
    // emit DelegateChanged(_account, oldDelegate, delegatee);
  }

  //   // TODO: prune zero adjustments, and sum all adjustments per delegate
  //   function _createDelegationAdjustments(FractionalDelegation[] memory _old, FractionalDelegation[] memory _new)
  //     internal
  //     returns (DelegationAdjustment[] memory)
  //   {
  //     DelegationAdjustment[] memory _delegationAdjustments = new DelegationAdjustment[](_old.length + _new.length);
  //     for (uint256 i = 0; i < _old.length; i++) {
  //       _delegationAdjustments[i] =
  //         DelegationAdjustment({_delegatee: _old[i]._delegatee, _amount: _old[i]._numerator, _isAddition: false});
  //     }
  //     for (uint256 i = 0; i < _new.length; i++) {
  //       _delegationAdjustments[i + _old.length] =
  //         DelegationAdjustment({_delegatee: _new[i]._delegatee, _amount: _new[i]._numerator, _isAddition: true});
  //     }
  //     return _delegationAdjustments;
  //   }

  /**
   * @dev Transfers, mints, or burns voting units. To register a mint, `from` should be zero. To register a burn, `to`
   * should be zero. Total supply of voting units will be adjusted with mints and burns.
   */
  function _transferVotingUnits(address from, address to, uint256 amount) internal virtual {
    VotesFractionalDelegationStorage storage $ = _getVotesFractionalDelegationStorage();
    if (from == address(0)) {
      _push($._totalCheckpoints, _add, SafeCast.toUint208(amount));
    }
    if (to == address(0)) {
      _push($._totalCheckpoints, _subtract, SafeCast.toUint208(amount));
    }
    // This case is more complicated than a delegation.
    DelegationAdjustment[] memory _delegationAdjustments = _calculateDelegateVoteAdjustments(from, to, amount);
    _adjustDelegateVotes(_delegationAdjustments);
  }

  function _calculateDelegateVoteAdjustments(address from, address to, uint256 amount)
    internal
    virtual
    returns (DelegationAdjustment[] memory)
  {
    VotesFractionalDelegationStorage storage $ = _getVotesFractionalDelegationStorage();

    // get old weights
    DelegationAdjustment[] memory _from =
      _calculateWeightDistribution($._delegatees[from], _getVotingUnits(from), false);
    DelegationAdjustment[] memory _to = _calculateWeightDistribution($._delegatees[to], _getVotingUnits(to), false);

    // calculate new weights
    DelegationAdjustment[] memory _fromNew =
      _calculateWeightDistribution($._delegatees[from], _getVotingUnits(from) - amount, true);
    DelegationAdjustment[] memory _toNew =
      _calculateWeightDistribution($._delegatees[to], amount + _getVotingUnits(to), true);

    // calculate adjustments
    // TODO: prune zero adjustments, sum all adjustments per delegate
    DelegationAdjustment[] memory _delegationAdjustments = new DelegationAdjustment[](_from.length + _to.length);
    for (uint256 i = 0; i < _from.length; i++) {
      _delegationAdjustments[i] = DelegationAdjustment({
        _delegatee: $._delegatees[from][i]._delegatee,
        _amount: _from[i]._amount - _fromNew[i]._amount,
        _isAddition: false
      });
    }
    for (uint256 i = 0; i < _to.length; i++) {
      _delegationAdjustments[i + _from.length] = DelegationAdjustment({
        _delegatee: $._delegatees[to][i]._delegatee,
        _amount: _toNew[i]._amount - _to[i]._amount,
        _isAddition: true
      });
    }
    return _delegationAdjustments;
  }

  /// @dev _delegationAdjustments array should already be totaled and pruned.
  /// totaled: all additions and subtractions should be summed per delegate
  /// pruned: all zero adjustments should be removed
  function _adjustDelegateVotes(DelegationAdjustment[] memory _delegationAdjustments) internal {
    VotesFractionalDelegationStorage storage $ = _getVotesFractionalDelegationStorage();
    for (uint256 i = 0; i < _delegationAdjustments.length; i++) {
      function(uint208, uint208) view returns (uint208) _op = _delegationAdjustments[i]._isAddition ? _add : _subtract;
      (uint256 oldValue, uint256 newValue) = _push(
        $._delegateCheckpoints[_delegationAdjustments[i]._delegatee],
        _op,
        SafeCast.toUint208(_delegationAdjustments[i]._amount)
      );
      // TODO: emit event
      // emit DelegateVotesChanged(_delegationAdjustments[i]._delegatee, oldValue, newValue);
    }
  }

  function _calculateWeightDistribution(FractionalDelegation[] memory _delegations, uint256 _amount, bool _isAddition)
    internal
    pure
    returns (DelegationAdjustment[] memory)
  {
    DelegationAdjustment[] memory _delegationAdjustments = new DelegationAdjustment[](_delegations.length);
    uint256 _total = 0;
    for (uint256 i = 0; i < _delegations.length; i++) {
      _delegationAdjustments[i] = DelegationAdjustment(
        _delegations[i]._delegatee, uint208(_amount) * _delegations[i]._numerator / DENOMINATOR, _isAddition
      );
      _total += _delegationAdjustments[i]._amount;
    }
    // assign remaining weight to first delegatee
    if (_total < _amount) {
      _delegationAdjustments[0]._amount += uint208(_amount - _total);
    }
    return _delegationAdjustments;
  }

  /**
   * @dev Get number of checkpoints for `account`.
   */
  function _numCheckpoints(address account) internal view virtual returns (uint32) {
    VotesFractionalDelegationStorage storage $ = _getVotesFractionalDelegationStorage();
    return SafeCast.toUint32($._delegateCheckpoints[account].length());
  }

  /**
   * @dev Get the `pos`-th checkpoint for `account`.
   */
  function _checkpoints(address account, uint32 pos) internal view virtual returns (Checkpoints.Checkpoint208 memory) {
    VotesFractionalDelegationStorage storage $ = _getVotesFractionalDelegationStorage();
    return $._delegateCheckpoints[account].at(pos);
  }

  function _push(
    Checkpoints.Trace208 storage store,
    function(uint208, uint208) view returns (uint208) op,
    uint208 delta
  ) private returns (uint208, uint208) {
    return store.push(clock(), op(store.latest(), delta));
  }

  function _add(uint208 a, uint208 b) private pure returns (uint208) {
    return a + b;
  }

  function _subtract(uint208 a, uint208 b) private pure returns (uint208) {
    return a - b;
  }

  /**
   * @dev Must return the voting units held by an account.
   */
  function _getVotingUnits(address) internal view virtual returns (uint256);
}
