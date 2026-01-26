// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

interface IFlashLoanEtherReceiver {
    function execute() external payable;
}

contract SideEntranceLenderPool {
    mapping(address => uint256) public balances;

    error RepayFailed();

    event Deposit(address indexed who, uint256 amount);
    event Withdraw(address indexed who, uint256 amount);

    /**
     * @audit This contract is missing a fallback or receive function, deposit() is the only payable function on the contract
     * Without a payable fallback or receive function this is the only way to return funds after a flash loan
     * If funds are returned through the deposit function then the msg.sender who called the flash loan will wrongly be credited the entire flash loan amount to their balances mapping
     * Then the user will have a deposited balance that they can return to withdraw later, thereby draining the contract of funds
     */
    function deposit() external payable {
        unchecked {
            balances[msg.sender] += msg.value;
        }
        emit Deposit(msg.sender, msg.value);
    }

    function withdraw() external {
        uint256 amount = balances[msg.sender];

        delete balances[msg.sender];
        emit Withdraw(msg.sender, amount);

        SafeTransferLib.safeTransferETH(msg.sender, amount);
    }

    function flashLoan(uint256 amount) external {
        uint256 balanceBefore = address(this).balance;

        IFlashLoanEtherReceiver(msg.sender).execute{value: amount}();

        /**
         * @audit this check would normally be fine but a severe vulnerability is created when it is combined with the deposit function, and the missing fallback/receive function
         * Since address(this).balance is checked and the deposit function is not disabled during a flash loan, this can be manipulated by simply depositing the ETH instead of returning it through a fallback or receive function
         * In fact, without a way to receive ETH the caller is forced to return the ETH though the deposit function as that is the only payable function in the contract
         * By doing this, users gain a deposited balance just by returning a flash loan
         */
        if (address(this).balance < balanceBefore) {
            revert RepayFailed();
        }
    }
}
