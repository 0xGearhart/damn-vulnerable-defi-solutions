// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {BitMaps} from "@openzeppelin/contracts/utils/structs/BitMaps.sol";

struct Distribution {
    uint256 remaining;
    uint256 nextBatchNumber;
    mapping(uint256 batchNumber => bytes32 root) roots;
    mapping(address claimer => mapping(uint256 word => uint256 bits)) claims;
}

struct Claim {
    uint256 batchNumber;
    uint256 amount;
    uint256 tokenIndex;
    bytes32[] proof;
}

/**
 * An efficient token distributor contract based on Merkle proofs and bitmaps
 */
contract TheRewarderDistributor {
    using BitMaps for BitMaps.BitMap;

    address public immutable owner = msg.sender;

    mapping(IERC20 token => Distribution) public distributions;

    error StillDistributing();
    error InvalidRoot();
    error AlreadyClaimed();
    error InvalidProof();
    error NotEnoughTokensToDistribute();

    event NewDistribution(IERC20 token, uint256 batchNumber, bytes32 newMerkleRoot, uint256 totalAmount);

    function getRemaining(address token) external view returns (uint256) {
        return distributions[IERC20(token)].remaining;
    }

    function getNextBatchNumber(address token) external view returns (uint256) {
        return distributions[IERC20(token)].nextBatchNumber;
    }

    function getRoot(address token, uint256 batchNumber) external view returns (bytes32) {
        return distributions[IERC20(token)].roots[batchNumber];
    }

    function createDistribution(IERC20 token, bytes32 newRoot, uint256 amount) external {
        if (amount == 0) revert NotEnoughTokensToDistribute();
        if (newRoot == bytes32(0)) revert InvalidRoot();
        if (distributions[token].remaining != 0) revert StillDistributing();

        distributions[token].remaining = amount;

        uint256 batchNumber = distributions[token].nextBatchNumber;
        distributions[token].roots[batchNumber] = newRoot;
        distributions[token].nextBatchNumber++;

        SafeTransferLib.safeTransferFrom(address(token), msg.sender, address(this), amount);

        emit NewDistribution(token, batchNumber, newRoot, amount);
    }

    function clean(IERC20[] calldata tokens) external {
        for (uint256 i = 0; i < tokens.length; i++) {
            IERC20 token = tokens[i];
            if (distributions[token].remaining == 0) {
                token.transfer(owner, token.balanceOf(address(this)));
            }
        }
    }

    // Allow claiming rewards of multiple tokens in a single transaction
    function claimRewards(Claim[] memory inputClaims, IERC20[] memory inputTokens) external {
        Claim memory inputClaim;
        IERC20 token;
        uint256 bitsSet; // accumulator
        uint256 amount;

        for (uint256 i = 0; i < inputClaims.length; i++) {
            inputClaim = inputClaims[i];

            uint256 wordPosition = inputClaim.batchNumber / 256;
            uint256 bitPosition = inputClaim.batchNumber % 256;

            // @audit this check only advances if the current token in the array is different from the last
            // This means if the next token in the array is the same token as the last, then it will never reach the statement that checks if they have already claimed and sets it to true
            // To solve the challenge, we can just send an array full of duplicate claims since the _setClaimed only checks once a different token is used
            // This allows us to drain the contract with a single valid proof duplicated as many times as we need to take all weth and dvt tokens in increments of the valid proofs claim amount
            if (token != inputTokens[inputClaim.tokenIndex]) {
                if (address(token) != address(0)) {
                    if (!_setClaimed(token, amount, wordPosition, bitsSet)) revert AlreadyClaimed();
                }

                token = inputTokens[inputClaim.tokenIndex];
                bitsSet = 1 << bitPosition; // set bit at given position
                amount = inputClaim.amount;
            } else {
                bitsSet = bitsSet | 1 << bitPosition;
                amount += inputClaim.amount;
            }

            // for the last claim
            if (i == inputClaims.length - 1) {
                // @audit This _setClaimed check also only hits if it is the last token/claim in the array
                // Since each claim is not checked individually, we can send an array with hundreds of duplicate valid DVT claims followed by hundreds of duplicate valid WETH claims in a single array
                // This allows us to skip the first _setClaimed check until we move to the WETH claims and this last one is avoided by doing all the duplicate claims in one transaction so this check isn't hit until we are done draining all the DVT and WETH
                // In short, the claims mapping for DVT is only set to true once we switch to WETH (after all the DVT is drained) and the claims mapping for WETH is only set to true once we hit the last claim in the array (after all the WETH is drained)
                if (!_setClaimed(token, amount, wordPosition, bitsSet)) revert AlreadyClaimed();
            }

            bytes32 leaf = keccak256(abi.encodePacked(msg.sender, inputClaim.amount));
            bytes32 root = distributions[token].roots[inputClaim.batchNumber];

            if (!MerkleProof.verify(inputClaim.proof, root, leaf)) revert InvalidProof();

            inputTokens[inputClaim.tokenIndex].transfer(msg.sender, inputClaim.amount);
        }
    }

    function _setClaimed(IERC20 token, uint256 amount, uint256 wordPosition, uint256 newBits) private returns (bool) {
        uint256 currentWord = distributions[token].claims[msg.sender][wordPosition];
        if ((currentWord & newBits) != 0) return false;

        // update state
        distributions[token].claims[msg.sender][wordPosition] = currentWord | newBits;
        distributions[token].remaining -= amount;

        return true;
    }
}
