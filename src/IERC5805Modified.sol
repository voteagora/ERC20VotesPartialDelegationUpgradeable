// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IVotesPartialDelegation} from "src/IVotesPartialDelegation.sol";
import {IERC6372} from "@openzeppelin/contracts/interfaces/IERC6372.sol";

/**
 * @dev Interface that mostly supports the ERC5805 standard, but with a modified IVotes that more appropriately
 * describes partial delegation.
 */
interface IERC5805Modified is IERC6372, IVotesPartialDelegation {}
