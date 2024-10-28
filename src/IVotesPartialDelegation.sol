// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC6372} from "@openzeppelin/contracts/interfaces/IERC6372.sol";

struct PartialDelegation {
  address _delegatee;
  uint96 _numerator;
}

struct DelegationAdjustment {
  address _delegatee;
  uint208 _amount;
}

/**
 * @dev Common interface for {ERC20VotesPartialDelegation} and other {VotesPartialDelegation}-enabled contracts.
 * @custom:security-contact security@voteagora.com
 */
interface IVotesPartialDelegation is IERC6372 {
  /**
   * @dev The signature used has expired.
   */
  error VotesExpiredSignature(uint256 expiry);

  /**
   * @dev Emitted when an account changes their delegate.
   */
  event DelegateChanged(
    address indexed delegator, PartialDelegation[] oldDelegatees, PartialDelegation[] newDelegatees
  );

  /**
   * @dev Emitted when a token transfer or delegate change results in changes to a delegate's number of voting units.
   */
  event DelegateVotesChanged(address indexed delegate, uint256 previousVotes, uint256 newVotes);

  /**
   * @dev Emitted when the votable supply changes.
   */
  event VotableSupplyChanged(uint256 previousSupply, uint256 newSupply);

  /**
   * @dev Returns the current amount of votes that `account` has.
   */
  function getVotes(address account) external view returns (uint256);

  /**
   * @dev Returns the amount of votes that `account` had at a specific moment in the past. If the `clock()` is
   * configured to use block numbers, this will return the value at the end of the corresponding block.
   */
  function getPastVotes(address account, uint256 timepoint) external view returns (uint256);

  /**
   * @dev Returns the total supply of votes available at a specific moment in the past. If the `clock()` is
   * configured to use block numbers, this will return the value at the end of the corresponding block.
   *
   * NOTE: This value is the sum of all available votes, which is not necessarily the sum of all delegated votes.
   * Votes that have not been delegated are still part of total supply, even though they would not participate in a
   * vote.
   */
  function getPastTotalSupply(uint256 timepoint) external view returns (uint256);

  /**
   * @dev Return the latest votable supply.
   */
  function getVotableSupply() external view returns (uint256);

  /**
   * @dev Return the votable supply at a given block number.
   */
  function getPastVotableSupply(uint256 timepoint) external view returns (uint256);

  /**
   * @dev Returns the delegate that `account` has chosen.
   * Removed: This function is incompatible with partial delegation, which allows for multiple delegates per account.
   */
  //   function delegates(address account) external view returns (address);

  /**
   * @dev Delegates votes from the sender to `delegatee`.
   */
  function delegate(address delegatee) external;

  /**
   * @dev Delegates votes from signer to `delegatee`.
   */
  function delegateBySig(address delegatee, uint256 nonce, uint256 expiry, uint8 v, bytes32 r, bytes32 s) external;
}
