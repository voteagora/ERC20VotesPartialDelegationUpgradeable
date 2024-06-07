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
import {PartialDelegation, DelegationAdjustment} from "src/IVotesPartialDelegation.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {console2} from "forge-std/console2.sol";

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
abstract contract VotesPartialDelegationUpgradeable is
  Initializable,
  ContextUpgradeable,
  EIP712Upgradeable,
  NoncesUpgradeable,
  IERC5805Modified
{
  using Checkpoints for Checkpoints.Trace208;

  /// @notice Emitted when an invalid signature is provided.
  error InvalidSignature();

  /// @notice Emitted when address zero is provided as admin.
  error InvalidAddressZero();

  /// @notice Emitted when the number of delegatees exceeds the limit.
  error PartialDelegationLimitExceeded(uint256 length, uint256 max);

  /// @notice Emitted when the provided delegatee list is not sorted or contains duplicates.
  error DuplicateOrUnsortedDelegatees(address delegatee);

  /// @notice Emitted when the provided numerator is zero.
  error InvalidNumeratorZero();

  /// @notice Emitted when the sum of the numerators exceeds the denominator.
  error NumeratorSumExceedsDenominator(uint256 numerator, uint96 denominator);

  /// @notice Typehash for legacy delegation.
  /// @custom:legacy
  bytes32 public constant DELEGATION_TYPEHASH = keccak256("Delegation(address delegatee,uint256 nonce,uint256 expiry)");
  /// @notice Typehash for partial delegation.
  bytes32 public constant PARTIAL_DELEGATION_ON_BEHALF_TYPEHASH = keccak256(
    "PartialDelegationOnBehalf(address delegator,PartialDelegation[] delegations,uint256 nonce,uint256 expiry)PartialDelegation(address delegatee,uint96 numerator)"
  );
  /// @notice Typehash for partial delegation.
  bytes32 public constant PARTIAL_DELEGATION_TYPEHASH =
    keccak256("PartialDelegation(address delegatee,uint96 numerator)");
  /// @notice Max # of partial delegations that can be specified in a partial delegation set.
  uint256 public constant MAX_PARTIAL_DELEGATIONS = 100;
  /// @notice Denominator of a partial delegation fraction.
  uint96 public constant DENOMINATOR = 10_000;

  enum Op {
    ADD,
    SUBTRACT
  }

  /// @custom:storage-location erc7201:storage.VotesPartialDelegation
  struct VotesPartialDelegationStorage {
    mapping(address account => PartialDelegation[]) _delegatees;
    mapping(address delegatee => Checkpoints.Trace208) _delegateCheckpoints;
    Checkpoints.Trace208 _totalCheckpoints;
  }

  // keccak256(abi.encode(uint256(keccak256("storage.VotesPartialDelegation")) - 1)) &~bytes32(uint256(0xff))
  bytes32 private constant VotesPartialDelegationStorageLocation =
    0x60b289dca0c170df62b40d5e0313a4c0e665948cd979375ddb3db607c1b89f00;

  function _getVotesPartialDelegationStorage() private pure returns (VotesPartialDelegationStorage storage $) {
    assembly {
      $.slot := VotesPartialDelegationStorageLocation
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

  function __VotesPartialDelegation_init() internal onlyInitializing {}

  function __VotesPartialDelegation_init_unchained() internal onlyInitializing {}

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
    VotesPartialDelegationStorage storage $ = _getVotesPartialDelegationStorage();
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
    VotesPartialDelegationStorage storage $ = _getVotesPartialDelegationStorage();
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
    VotesPartialDelegationStorage storage $ = _getVotesPartialDelegationStorage();
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
    VotesPartialDelegationStorage storage $ = _getVotesPartialDelegationStorage();
    return $._totalCheckpoints.latest();
  }

  /**
   * @notice Returns the delegates that `account` has chosen.
   * @param account The delegator's address.
   */
  function delegates(address account) public view virtual returns (PartialDelegation[] memory) {
    VotesPartialDelegationStorage storage $ = _getVotesPartialDelegationStorage();
    return $._delegatees[account];
  }

  /**
   * @notice Delegates 100% of sender's votes to `delegatee`.
   * @param delegatee The address to delegate votes to.
   * @custom:legacy
   */
  function delegate(address delegatee) public virtual {
    address account = _msgSender();
    PartialDelegation[] memory delegations = new PartialDelegation[](1);
    delegations[0] = PartialDelegation(delegatee, DENOMINATOR);
    _delegate(account, delegations);
  }

  /**
   * @notice Delegates votes from the sender to any number of `PartialDelegation._delegatee`s, up to
   * `MAX_PARTIAL_DELEGATIONS`. A partial delegation consists of a delegatee and a numerator which will act as a
   * percentage (i.e. with DENOMINATOR set to 10_000, a numerator of 1_000 will be a 10% delegation). When passing the
   * partial delegation items to this method, it's required to sort them by delegatee, with no duplicates. Otherwise,
   * the call will revert. Additionally, the sum of the array's numerators must not exceed DENOMINATOR.
   * @param _partialDelegations The array of partial delegations to delegate to.
   * @dev Reverts if the number of partial delegations exceeds `MAX_PARTIAL_DELEGATIONS`.
   * Reverts if the sum of the numerators in `_partialDelegations` exceeds `DENOMINATOR`.
   * Reverts if the delegations are not sorted or contain duplicates.
   * Emits {DelegateChanged} and {DelegateVotesChanged} events.
   */
  function delegate(PartialDelegation[] calldata _partialDelegations) public virtual {
    address account = _msgSender();
    _delegate(account, _partialDelegations);
  }

  /**
   * @notice Delegates 100% of votes from signer to `delegatee`.
   * @param delegatee The address to delegate votes to.
   * @param nonce The signer's nonce.
   * @param expiry The timestamp at which the signature expires.
   * @param v The recovery byte of the signature.
   * @param r Half of the ECDSA signature pair.
   * @param s Half of the ECDSA signature pair.
   * @custom:legacy
   */
  function delegateBySig(address delegatee, uint256 nonce, uint256 expiry, uint8 v, bytes32 r, bytes32 s)
    public
    virtual
  {
    if (block.timestamp > expiry) {
      revert VotesExpiredSignature(expiry);
    }
    address signer =
      ECDSA.recover(_hashTypedDataV4(keccak256(abi.encode(DELEGATION_TYPEHASH, delegatee, nonce, expiry))), v, r, s);
    _useCheckedNonce(signer, nonce);
    PartialDelegation[] memory _partialDelegations = new PartialDelegation[](1);
    _partialDelegations[0] = PartialDelegation(delegatee, DENOMINATOR);
    _delegate(signer, _partialDelegations);
  }

  /**
   * @notice Delegates votes from signer to any number of `_partialDelegations`, up to `MAX_PARTIAL_DELEGATIONS`. A
   * partial delegation consists of a delegatee and a numerator which will act as a percentage (i.e. with DENOMINATOR
   * set to 10_000, a numerator of 1_000 will be a 10% delegation). When passing the partial delegation items to this
   * method, it's required to sort them by delegatee, with no duplicates. Otherwise, the call will revert. Additionally,
   * the sum of the array's numerators must not exceed DENOMINATOR.
   * @param _delegator The signer who is delegating votes.
   * @param _partialDelegations The array of partial delegations to delegate to.
   * @param _nonce The signer's nonce.
   * @param _expiry The timestamp at which the signature expires.
   * @param _signature The EIP712/ERC1271 signature from the signer.
   * @dev Reverts if the signature is invalid, expired, or if the number of partial delegations exceeds
   * `MAX_PARTIAL_DELEGATIONS`.
   * Reverts if the sum of the numerators in `_partialDelegations` exceeds `DENOMINATOR`.
   * Reverts if the delegations are not sorted or contain duplicates.
   * Emits {DelegateChanged} and {DelegateVotesChanged} events.
   */
  function delegatePartiallyOnBehalf(
    address _delegator,
    PartialDelegation[] memory _partialDelegations,
    uint256 _nonce,
    uint256 _expiry,
    bytes calldata _signature
  ) public virtual {
    if (block.timestamp > _expiry) {
      revert VotesExpiredSignature(_expiry);
    }
    bytes32[] memory _partialDelegationsPayload = new bytes32[](_partialDelegations.length);
    for (uint256 i = 0; i < _partialDelegations.length; i++) {
      _partialDelegationsPayload[i] = _hash(_partialDelegations[i]);
    }

    bool _isValidSignature = SignatureChecker.isValidSignatureNow(
      _delegator,
      _hashTypedDataV4(
        keccak256(
          abi.encode(
            PARTIAL_DELEGATION_ON_BEHALF_TYPEHASH,
            _delegator,
            keccak256(abi.encodePacked(_partialDelegationsPayload)),
            _nonce,
            _expiry
          )
        )
      ),
      _signature
    );

    if (!_isValidSignature) {
      revert InvalidSignature();
    }
    _useCheckedNonce(_delegator, _nonce);
    _delegate(_delegator, _partialDelegations);
  }

  /**
   * @dev Delegate all of `_delegator`'s voting units to delegates specified in `_newDelegations`.
   * Emits events {IVotes-DelegateChanged} and {IVotes-DelegateVotesChanged}.
   */
  function _delegate(address _delegator, PartialDelegation[] memory _newDelegations) internal virtual {
    if (_newDelegations.length > MAX_PARTIAL_DELEGATIONS) {
      revert PartialDelegationLimitExceeded(_newDelegations.length, MAX_PARTIAL_DELEGATIONS);
    }

    VotesPartialDelegationStorage storage $ = _getVotesPartialDelegationStorage();

    // Subtract votes from old delegatee set, if it exists.
    PartialDelegation[] memory _oldDelegations = delegates(_delegator);
    uint256 _oldDelegateLength = _oldDelegations.length;
    DelegationAdjustment[] memory _old = new DelegationAdjustment[](_oldDelegateLength);
    if (_oldDelegateLength > 0) {
      _old = _calculateWeightDistribution(_oldDelegations, _getVotingUnits(_delegator));
    }

    // Calculate adjustments for new delegatee set.
    DelegationAdjustment[] memory _new = _calculateWeightDistribution(_newDelegations, _getVotingUnits(_delegator));

    // Now we want a collated list of all delegatee changes, combining the old subtractions with the new additions.
    // Ideally we'd like to process this only once.
    _aggregateDelegationAdjustmentsAndCreateCheckpoints(_old, _new);

    // The rest of this method body replaces in storage the old delegatees with the new ones.
    // keep track of last delegatee to ensure ordering / uniqueness
    address _lastDelegatee;
    PartialDelegation[] memory _oldDelegates = $._delegatees[_delegator];

    for (uint256 i = 0; i < _newDelegations.length; i++) {
      // check sorting and uniqueness
      if (i == 0 && _newDelegations[i]._delegatee == address(0)) {
        // zero delegation is allowed if in 0th position
      } else if (_newDelegations[i]._delegatee <= _lastDelegatee) {
        revert DuplicateOrUnsortedDelegatees(_newDelegations[i]._delegatee);
      }

      // replace existing delegatees in storage
      if (i < _oldDelegateLength) {
        $._delegatees[_delegator][i] = _newDelegations[i];
      }
      // or add new delegatees
      else {
        $._delegatees[_delegator].push(_newDelegations[i]);
      }
      _lastDelegatee = _newDelegations[i]._delegatee;
    }
    // remove any remaining old delegatees
    if (_oldDelegateLength > _newDelegations.length) {
      for (uint256 i = _newDelegations.length; i < _oldDelegateLength; i++) {
        $._delegatees[_delegator].pop();
      }
    }
    // emit events
    _emitDelegationEvents(_delegator, _oldDelegates, _newDelegations);
  }

  /// @dev Emits {DelegateChanged} events for each change in delegation, taking care to avoid duplicates and no-ops.
  function _emitDelegationEvents(address _delegator, PartialDelegation[] memory _old, PartialDelegation[] memory _new)
    internal
    virtual
  {
    uint256 i;
    uint256 j;
    while (i < _old.length || j < _new.length) {
      if (i < _old.length && j < _new.length && _old[i]._delegatee == _new[j]._delegatee) {
        if (_old[i]._numerator != _new[j]._numerator) {
          emit DelegateChanged(_delegator, _new[j]._delegatee, _new[j]._numerator);
        }
        i++;
        j++;
      } else if (j == _new.length || (i != _old.length && _old[i]._delegatee < _new[j]._delegatee)) {
        emit DelegateChanged(_delegator, _old[i]._delegatee, 0);
        i++;
      } else {
        emit DelegateChanged(_delegator, _new[j]._delegatee, _new[j]._numerator);
        j++;
      }
    }
  }

  /**
   * @dev Given an old delegation array and a new delegation array, determine which delegations have changed, create new
   * voting checkpoints, and emit a {DelegateVotesChanged} event. Takes care to avoid duplicates and no-ops.
   * Assumes both _old and _new are sorted by `DelegationAdjustment._delegatee`.
   */
  function _aggregateDelegationAdjustmentsAndCreateCheckpoints(
    DelegationAdjustment[] memory _old,
    DelegationAdjustment[] memory _new
  ) internal {
    VotesPartialDelegationStorage storage $ = _getVotesPartialDelegationStorage();
    // start with ith member of _old and jth member of _new.
    // If they are the same delegatee, combine them, check if result is 0, and iterate i and j.
    // If _old[i] > _new[j], add _new[j] to the final array and iterate j. If _new[j] > _old[i], add _old[i] and iterate
    // i.
    uint256 i = 0;
    uint256 j = 0;
    while (i < _old.length || j < _new.length) {
      DelegationAdjustment memory _delegationAdjustment;
      Op _op;

      // same address is present in both arrays
      if (i < _old.length && j < _new.length && _old[i]._delegatee == _new[j]._delegatee) {
        // combine, checkpoint, and iterate
        _delegationAdjustment._delegatee = _old[i]._delegatee;
        if (_old[i]._amount != _new[j]._amount) {
          if (_old[i]._amount > _new[j]._amount) {
            _op = Op.SUBTRACT;
            _delegationAdjustment._amount = _old[i]._amount - _new[j]._amount;
          } else {
            _op = Op.ADD;
            _delegationAdjustment._amount = _new[j]._amount - _old[i]._amount;
          }
        }
        i++;
        j++;
      } else if (
        j == _new.length // if we've exhausted the new array, we can just checkpoint the old values
          || (i != _old.length && _old[i]._delegatee < _new[j]._delegatee) // or, if the ith old delegatee is next in line
      ) {
        // skip if 0...
        _delegationAdjustment._delegatee = _old[i]._delegatee;
        if (_old[i]._amount != 0) {
          _op = Op.SUBTRACT;
          _delegationAdjustment._amount = _old[i]._amount;
        }
        i++;
      } else {
        // skip if 0...
        _delegationAdjustment._delegatee = _new[j]._delegatee;
        if (_new[j]._amount != 0) {
          _op = Op.ADD;
          _delegationAdjustment._amount = _new[j]._amount;
        }
        j++;
      }

      if (_delegationAdjustment._amount != 0) {
        (uint256 oldValue, uint256 newValue) = _push(
          $._delegateCheckpoints[_delegationAdjustment._delegatee],
          _operation(_op),
          SafeCast.toUint208(_delegationAdjustment._amount)
        );

        emit DelegateVotesChanged(_delegationAdjustment._delegatee, oldValue, newValue);
      }
    }
  }

  /**
   * @dev Transfers, mints, or burns voting units. To register a mint, `from` should be zero. To register a burn, `to`
   * should be zero. Total supply of voting units will be adjusted with mints and burns.
   */
  function _transferVotingUnits(address from, address to, uint256 amount) internal virtual {
    // skip from==to case, as the math would require special handling for a no-op
    if (from == to) {
      return;
    }

    // update total supply checkpoints if mint/burn
    VotesPartialDelegationStorage storage $ = _getVotesPartialDelegationStorage();
    if (from == address(0)) {
      _push($._totalCheckpoints, _add, SafeCast.toUint208(amount));
    }
    if (to == address(0)) {
      _push($._totalCheckpoints, _subtract, SafeCast.toUint208(amount));
    }

    // finally, calculate delegatee vote changes and create checkpoints accordingly
    _calculateDelegateVoteAdjustmentsAndCreateCheckpoints(from, to, amount);
  }

  /**
   * @dev Calculate the vote weight adjustments for `from` and `to` delegatees and create checkpoints accordingly.
   */
  function _calculateDelegateVoteAdjustmentsAndCreateCheckpoints(address from, address to, uint256 amount)
    internal
    virtual
  {
    VotesPartialDelegationStorage storage $ = _getVotesPartialDelegationStorage();
    DelegationAdjustment[] memory _delegationAdjustmentsFrom = new DelegationAdjustment[]($._delegatees[from].length);
    // We'll need to adjust the delegatee votes for both "from" and "to" delegatee sets.
    if ($._delegatees[from].length > 0) {
      DelegationAdjustment[] memory _from = _calculateWeightDistribution($._delegatees[from], _getVotingUnits(from));
      DelegationAdjustment[] memory _fromNew =
        _calculateWeightDistribution($._delegatees[from], _getVotingUnits(from) - amount);

      for (uint256 i = 0; i < _from.length; i++) {
        _delegationAdjustmentsFrom[i] = DelegationAdjustment({
          _delegatee: $._delegatees[from][i]._delegatee,
          _amount: _from[i]._amount - _fromNew[i]._amount
        });
      }
    }

    DelegationAdjustment[] memory _delegationAdjustmentsTo = new DelegationAdjustment[]($._delegatees[to].length);
    if ($._delegatees[to].length > 0) {
      DelegationAdjustment[] memory _to = _calculateWeightDistribution($._delegatees[to], _getVotingUnits(to));
      DelegationAdjustment[] memory _toNew =
        _calculateWeightDistribution($._delegatees[to], amount + _getVotingUnits(to));

      for (uint256 i = 0; i < _to.length; i++) {
        _delegationAdjustmentsTo[i] = (
          DelegationAdjustment({
            _delegatee: $._delegatees[to][i]._delegatee,
            _amount: _toNew[i]._amount - _to[i]._amount
          })
        );
      }
    }
    _aggregateDelegationAdjustmentsAndCreateCheckpoints(_delegationAdjustmentsFrom, _delegationAdjustmentsTo);
  }

  /**
   * @dev Internal helper to calculate vote weights from a list of delegations. It reverts if the sum of the numerators
   * is greater than DENOMINATOR.
   */
  function _calculateWeightDistribution(PartialDelegation[] memory _delegations, uint256 _amount)
    internal
    pure
    returns (DelegationAdjustment[] memory)
  {
    DelegationAdjustment[] memory _delegationAdjustments = new DelegationAdjustment[](_delegations.length);

    // Keep track of total numerator to ensure it doesn't exceed DENOMINATOR
    uint256 _totalNumerator = 0;

    // Iterate through partial delegations to calculate vote weight
    for (uint256 i = 0; i < _delegations.length; i++) {
      if (_delegations[i]._numerator == 0) {
        revert InvalidNumeratorZero();
      }
      _delegationAdjustments[i] =
        DelegationAdjustment(_delegations[i]._delegatee, uint208(_amount * _delegations[i]._numerator / DENOMINATOR));
      _totalNumerator += _delegations[i]._numerator;
    }
    if (_totalNumerator > DENOMINATOR) {
      revert NumeratorSumExceedsDenominator(_totalNumerator, DENOMINATOR);
    }
    return _delegationAdjustments;
  }

  /**
   * @dev Get number of checkpoints for `account`.
   */
  function _numCheckpoints(address account) internal view virtual returns (uint32) {
    VotesPartialDelegationStorage storage $ = _getVotesPartialDelegationStorage();
    return SafeCast.toUint32($._delegateCheckpoints[account].length());
  }

  /**
   * @dev Get the `pos`-th checkpoint for `account`.
   */
  function _checkpoints(address account, uint32 pos) internal view virtual returns (Checkpoints.Checkpoint208 memory) {
    VotesPartialDelegationStorage storage $ = _getVotesPartialDelegationStorage();
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

  function _operation(Op op) internal pure returns (function(uint208, uint208) view returns (uint208)) {
    return op == Op.ADD ? _add : _subtract;
  }

  function _hash(PartialDelegation memory partialDelegation) internal pure returns (bytes32) {
    return
      keccak256(abi.encode(PARTIAL_DELEGATION_TYPEHASH, partialDelegation._delegatee, partialDelegation._numerator));
  }

  /**
   * @dev Must return the voting units held by an account.
   */
  function _getVotingUnits(address) internal view virtual returns (uint256);
}
