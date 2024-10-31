// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ContextUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";
import {NoncesUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/NoncesUpgradeable.sol";
import {EIP712Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import {Checkpoints} from "@openzeppelin/contracts/utils/structs/Checkpoints.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Time} from "@openzeppelin/contracts/utils/types/Time.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {PartialDelegation, DelegationAdjustment} from "src/IVotesPartialDelegation.sol";
import {IVotesPartialDelegation} from "src/IVotesPartialDelegation.sol";

import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {EnumerableMap} from "@openzeppelin/contracts/utils/structs/EnumerableMap.sol";

/**
 * @dev This is a base abstract contract that tracks voting units, which are a measure of voting power that can be
 * transferred, and provides a system of vote delegation, where an account can delegate its voting units to a sort of
 * "representative" that will pool delegated voting units from different accounts and can then use it to vote in
 * decisions. In fact, voting units _must_ be delegated in order to count as actual votes, and an account has to
 * delegate those votes to itself if it wishes to participate in decisions and does not have a trusted representative.
 *
 * This contract is often combined with a token contract such that voting units correspond to token units. For an
 * example, see {ERC20VotesPartialDelegationUpgradeable}.
 *
 * The full history of delegate votes is tracked on-chain so that governance protocols can consider votes as distributed
 * at a particular block number to protect against flash loans and double voting. The opt-in delegate system makes the
 * cost of this history tracking optional.
 *
 * When using this module the derived contract must implement {_getVotingUnits} (for example, make it return
 * {ERC721-balanceOf}), and can use {_transferVotingUnits} to track a change in the distribution of those units (in the
 * previous example, it would be included in {ERC721-_update}).
 * @custom:security-contact security@voteagora.com
 */
abstract contract VotesPartialDelegationUpgradeable is
  Initializable,
  ContextUpgradeable,
  EIP712Upgradeable,
  NoncesUpgradeable,
  IVotesPartialDelegation
{
  using EnumerableMap for EnumerableMap.AddressToUintMap;
  using Checkpoints for Checkpoints.Trace208;

  /// @custom:storage-location erc7201:storage.VotesPartialDelegation
  struct VotesPartialDelegationStorage {
    mapping(address account => PartialDelegation[]) _delegatees;
    mapping(address delegatee => Checkpoints.Trace208) _delegateCheckpoints;
    Checkpoints.Trace208 _totalCheckpoints;
    Checkpoints.Trace208 _votableSupplyCheckpoints;
  }

  /// @notice Store temporary delegation adjusments.
  EnumerableMap.AddressToUintMap private _adjustments;

  enum Op {
    ADD,
    SUBTRACT
  }

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
  // keccak256(abi.encode(uint256(keccak256("storage.VotesPartialDelegation")) - 1)) &~bytes32(uint256(0xff))
  bytes32 private constant VOTES_PARTIAL_DELEGATION_STORAGE_LOCATION =
    0x60b289dca0c170df62b40d5e0313a4c0e665948cd979375ddb3db607c1b89f00;

  /**
   * @dev The clock was incorrectly modified.
   */
  error ERC6372InconsistentClock();

  /**
   * @dev Lookup to future votes is not available.
   */
  error ERC5805FutureLookup(uint256 timepoint, uint48 clock);

  /// @notice Invalid signature is provided.
  error InvalidSignature();

  /// @notice Address zero is provided as admin.
  error InvalidAddressZero();

  /// @notice The number of delegatees exceeds the limit.
  error PartialDelegationLimitExceeded(uint256 length, uint256 max);

  /// @notice The provided delegatee list is not sorted or contains duplicates.
  error DuplicateOrUnsortedDelegatees(address delegatee);

  /// @notice The provided numerator is zero.
  error InvalidNumeratorZero();

  /// @notice The sum of the numerators exceeds the denominator.
  error NumeratorSumExceedsDenominator(uint256 numerator, uint96 denominator);

  function __VotesPartialDelegation_init() internal onlyInitializing {}

  function __VotesPartialDelegation_init_unchained() internal onlyInitializing {}

  function _getVotesPartialDelegationStorage() private pure returns (VotesPartialDelegationStorage storage $) {
    assembly {
      $.slot := VOTES_PARTIAL_DELEGATION_STORAGE_LOCATION
    }
  }

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
   * @dev Returns the current total number of tokens that have been delegated for voting.
   *
   * This value represents the "votable supply," which is the sum of all tokens that have been delegated to
   * representatives.
   * Tokens that have not been delegated are not included in this count.
   *
   * NOTE: This value is the sum of all delegated votes at the current block.
   */
  function getVotableSupply() public view returns (uint256) {
    VotesPartialDelegationStorage storage $ = _getVotesPartialDelegationStorage();
    return $._votableSupplyCheckpoints.latest();
  }

  /**
   * @dev Returns the total number of tokens that were delegated for voting at a specific moment in the past.
   * If the `clock()` is configured to use block numbers, this will return the value at the end of the corresponding
   * block.
   *
   * This value represents the "votable supply" at a given timepoint, which is the sum of all tokens that were
   * delegated
   * to representatives at that specific moment.
   *
   * NOTE: This value is the sum of all delegated votes at the specified timepoint.
   *
   * Requirements:
   *
   * - `timepoint` must be in the past. If operating using block numbers, the block must be already mined.
   *
   * @param timepoint The block number or timestamp to query the votable supply at.
   */
  function getPastVotableSupply(uint256 timepoint) public view virtual returns (uint256) {
    VotesPartialDelegationStorage storage $ = _getVotesPartialDelegationStorage();
    uint48 currentTimepoint = clock();
    if (timepoint >= currentTimepoint) {
      revert ERC5805FutureLookup(timepoint, currentTimepoint);
    }
    return $._votableSupplyCheckpoints.upperLookupRecent(SafeCast.toUint48(timepoint));
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
    uint256 _partialDelegationsLength = _partialDelegations.length;
    bytes32[] memory _partialDelegationsPayload = new bytes32[](_partialDelegationsLength);
    for (uint256 i; i < _partialDelegationsLength; i++) {
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
   * @dev Allows an address to increment their nonce and therefore invalidate any pending signed
   * actions.
   */
  function invalidateNonce() external {
    _useNonce(msg.sender);
  }

  /**
   * @dev Delegate `_delegator`'s voting units to delegates specified in `_newDelegations`.
   * Emits events {IVotes-DelegateChanged} and {IVotes-DelegateVotesChanged}.
   */
  function _delegate(address _delegator, PartialDelegation[] memory _newDelegations) internal virtual {
    uint256 _newDelegationsLength = _newDelegations.length;
    if (_newDelegationsLength > MAX_PARTIAL_DELEGATIONS) {
      revert PartialDelegationLimitExceeded(_newDelegationsLength, MAX_PARTIAL_DELEGATIONS);
    }

    // Get current delegations.
    PartialDelegation[] memory _oldDelegations = delegates(_delegator);

    // Get current voting power.
    uint256 _delegatorVotes = _getVotingUnits(_delegator);

    // Net the old and new delegations and create checkpoints.
    _createCheckpoints(
      _calculateWeightDistribution(_oldDelegations, _delegatorVotes),
      _calculateWeightDistribution(_newDelegations, _delegatorVotes)
    );

    // Store the last delegatee to check for sorting and uniqueness.
    address _lastDelegatee;

    uint256 _oldDelegationsLength = _oldDelegations.length;

    VotesPartialDelegationStorage storage $ = _getVotesPartialDelegationStorage();

    // Store new delegations.
    for (uint256 i; i < _newDelegationsLength; i++) {
      // Check sorting and uniqueness of delegatees.
      if (i == 0 && _newDelegations[i]._delegatee == address(0)) {
        // zero delegation is allowed if in 0th position
      } else if (_newDelegations[i]._delegatee <= _lastDelegatee) {
        revert DuplicateOrUnsortedDelegatees(_newDelegations[i]._delegatee);
      }

      // Add new delegations by either updating or pushing.
      if (i < _oldDelegationsLength) {
        $._delegatees[_delegator][i] = _newDelegations[i];
      } else {
        $._delegatees[_delegator].push(_newDelegations[i]);
      }

      _lastDelegatee = _newDelegations[i]._delegatee;
    }

    // Remove any old delegations.
    if (_oldDelegationsLength > _newDelegationsLength) {
      for (uint256 i = _newDelegationsLength; i < _oldDelegationsLength; i++) {
        $._delegatees[_delegator].pop();
      }
    }

    emit DelegateChanged(_delegator, _oldDelegations, _newDelegations);
  }

  /**
   * @dev Given an old delegation array and a new delegation array, determine which delegations have changed, create
   * new
   * voting checkpoints, and emit a {DelegateVotesChanged} event. Takes care to avoid duplicates and no-ops.
   * Assumes both _old and _new are sorted by `DelegationAdjustment._delegatee`.
   */
  function _createCheckpoints(DelegationAdjustment[] memory _old, DelegationAdjustment[] memory _new) internal {
    VotesPartialDelegationStorage storage $ = _getVotesPartialDelegationStorage();

    uint256 _oldLength = _old.length;
    for (uint256 i; i < _oldLength; i++) {
      _adjustments.set(_old[i]._delegatee, _old[i]._amount);
    }

    uint256 _newLength = _new.length;
    for (uint256 i; i < _newLength; i++) {
      address delegatee = _new[i]._delegatee;
      if (delegatee == address(0)) {
        continue;
      }

      function(uint256, uint256) view returns (bool, uint256) op = Math.tryAdd;
      uint256 amount = _new[i]._amount;

      // Any duplicate delegations will revert in `_delegate`.
      if (_adjustments.contains(delegatee)) {
        uint256 oldAmount = _adjustments.get(delegatee);
        (amount, op) = oldAmount > amount ? (oldAmount - amount, Math.trySub) : (amount - oldAmount, Math.tryAdd);
        _adjustments.remove(delegatee);
      }

      (uint256 oldValue, uint256 newValue) = _push($._delegateCheckpoints[delegatee], op, amount);

      emit DelegateVotesChanged(delegatee, oldValue, newValue);
    }

    uint256 _adjustmentsLength = _adjustments.length();
    for (uint256 i; i < _adjustmentsLength; i++) {
      (address delegatee, uint256 amount) = _adjustments.at(0);
      (uint256 oldValue, uint256 newValue) = _push($._delegateCheckpoints[delegatee], Math.trySub, amount);

      _adjustments.remove(delegatee);

      emit DelegateVotesChanged(delegatee, oldValue, newValue);
    }
  }

  /**
   * @dev Transfers, mints, or burns voting units. To register a mint, `from` should be zero. To register a burn, `to`
   * should be zero. Total and votable supplies will be adjusted with mints and burns.
   */
  function _transferVotingUnits(address from, address to, uint256 amount) internal virtual {
    // Skip when addresses are equal or amount is zero.
    if (from == to || amount == 0) {
      return;
    }

    VotesPartialDelegationStorage storage $ = _getVotesPartialDelegationStorage();

    // Increase total supply checkpoint for mint
    if (from == address(0)) {
      _push($._totalCheckpoints, Math.tryAdd, amount);
    }

    // Decrease total supply checkpoint for burn
    if (to == address(0)) {
      _push($._totalCheckpoints, Math.trySub, amount);
    }

    // Create checkpoints for the `from` delegatees.
    uint256 _fromLength = $._delegatees[from].length;
    if (_fromLength > 0) {
      uint256 _fromVotes = _getVotingUnits(from);
      DelegationAdjustment[] memory _from = _calculateWeightDistribution($._delegatees[from], _fromVotes + amount);
      DelegationAdjustment[] memory _fromNew = _calculateWeightDistribution($._delegatees[from], _fromVotes);
      for (uint256 i; i < _fromLength; i++) {
        (uint256 oldValue, uint256 newValue) = _push(
          $._delegateCheckpoints[$._delegatees[from][i]._delegatee], Math.trySub, _from[i]._amount - _fromNew[i]._amount
        );

        emit DelegateVotesChanged($._delegatees[from][i]._delegatee, oldValue, newValue);
      }
    }

    // Create checkpoints for the `to` delegatees.
    uint256 _toLength = $._delegatees[to].length;
    if (_toLength > 0) {
      uint256 _toVotes = _getVotingUnits(to);
      DelegationAdjustment[] memory _to = _calculateWeightDistribution($._delegatees[to], _toVotes - amount);
      DelegationAdjustment[] memory _toNew = _calculateWeightDistribution($._delegatees[to], _toVotes);

      for (uint256 i; i < _toLength; i++) {
        (uint256 oldValue, uint256 newValue) = _push(
          $._delegateCheckpoints[$._delegatees[to][i]._delegatee], Math.tryAdd, _toNew[i]._amount - _to[i]._amount
        );

        emit DelegateVotesChanged($._delegatees[to][i]._delegatee, oldValue, newValue);
      }
    }
  }

  /**
   * @dev Internal helper to calculate vote weights from a list of delegations. It reverts if the sum of the numerators
   * is greater than DENOMINATOR.
   */
  function _calculateWeightDistribution(PartialDelegation[] memory _delegationSet, uint256 _balance)
    internal
    pure
    returns (DelegationAdjustment[] memory)
  {
    uint256 _delegationsLength = _delegationSet.length;
    DelegationAdjustment[] memory _delegationAdjustments = new DelegationAdjustment[](_delegationsLength);

    // Keep track of total numerator to ensure it doesn't exceed DENOMINATOR
    uint256 _total = 0;

    // Iterate through partial delegations to calculate delegation adjustments.
    for (uint256 i; i < _delegationsLength; i++) {
      uint256 numerator = _delegationSet[i]._numerator;

      if (numerator == 0) {
        revert InvalidNumeratorZero();
      }
      _delegationAdjustments[i] =
        DelegationAdjustment(_delegationSet[i]._delegatee, SafeCast.toUint208((_balance * numerator) / DENOMINATOR));
      _total += numerator;
      if (_total > DENOMINATOR) {
        revert NumeratorSumExceedsDenominator(_total, DENOMINATOR);
      }
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
    function(uint256, uint256) view returns (bool,uint256) op,
    uint256 delta
  ) private returns (uint256, uint256) {
    (bool success, uint256 value) = op(uint256(store.latest()), delta);
    // TODO: check bool?
    return store.push(clock(), SafeCast.toUint208(value));
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
