// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {DamnValuableToken} from "../DamnValuableToken.sol";

contract TrusterLenderPool is ReentrancyGuard {
    using Address for address;

    DamnValuableToken public immutable token;

    error RepayFailed();

    constructor(DamnValuableToken _token) {
        token = _token;
    }

    function flashLoan(uint256 amount, address borrower, address target, bytes calldata data)
        external
        nonReentrant
        returns (bool)
    {
        uint256 balanceBefore = token.balanceOf(address(this));

        token.transfer(borrower, amount);
        /**
         * @audit passing full control of the transaction to the function caller is very dangerous
         * This next line allows anyone to call any function an any contract with this contracts address as msg.sender
         *
         * To solve this challenge we start by calling this function with an amount of 0 so we don't have to worry about returning any funds
         * The real key to this vulnerability is the target and data input fields since we can encode any function selector and contract address
         * We will use these input fields to send the DVT contract address along with the "approve(address,uint256)" function selector
         * This allows us to approve our player address to spend an unlimited amount of DVT tokens on this contracts behalf since we will be calling with this address as msg.sender
         * After the approval we are free to transfer the entire DVT balance of this contract wherever we want using transferFrom
         */
        target.functionCall(data);

        if (token.balanceOf(address(this)) < balanceBefore) {
            revert RepayFailed();
        }

        return true;
    }
}
