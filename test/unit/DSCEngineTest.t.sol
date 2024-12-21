// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test, console} from "forge-std/Test.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppeline/contracts/mocks/ERC20Mock.sol";

contract DSCEngineTest is Test {
    DeployDSC deployer;
    DecentralizedStableCoin dsc;
    DSCEngine engine;
    HelperConfig config;
    address ethUsdPriceFeed;
    address btcUsdPriceFeed;
    address weth;
    address wbtc;

    address public USER = makeAddr("user");
    address public LIQUIDATOR = makeAddr("liquidator");
    uint256 public constant AMOUNT_COLLATERAL = 10 ether;
    uint256 public constant STARTING_ERC20_BALANCE = 10 ether;
    uint256 public constant AMOUNT_DSC_MINTED = 2 ether;

    function setUp() public {
        deployer = new DeployDSC();
        (dsc, engine, config) = deployer.run();
        (ethUsdPriceFeed, btcUsdPriceFeed, weth, wbtc,) = config.activeNetworkConfig();

        ERC20Mock(weth).mint(USER, STARTING_ERC20_BALANCE);
        ERC20Mock(weth).mint(LIQUIDATOR, STARTING_ERC20_BALANCE);
    }

    ///// constructor test /////

    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    function testRevertsIfTokenLengthDoesntMatchPriceFeeds() public {
        tokenAddresses.push(weth);
        priceFeedAddresses.push(ethUsdPriceFeed);
        priceFeedAddresses.push(btcUsdPriceFeed);

        vm.expectRevert(DSCEngine.DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength.selector);
        new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
    }

    /////Price Test /////

    function testGetUsdValue() public view {
        uint256 ethAmount = 15e18;
        uint256 expectedAmount = 30000e18;
        uint256 actualUsd = engine.getUsdValue(weth, ethAmount);
        assertEq(expectedAmount, actualUsd);
    }

    function testGetTokenAmountFromUsd() public view {
        uint256 usdAmount = 100 ether;
        uint256 expectedWeth = 0.05 ether;

        uint256 actualWeth = engine.getTokenAmountFromUsd(weth, usdAmount);
        assertEq(expectedWeth, actualWeth);
    }

    ///// Deposit collateral test /////

    function testRevertsIfCollateralZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);

        vm.expectRevert(DSCEngine.DSCEngine__NeedMoreThanZero.selector);
        engine.depositCollateral(weth, 0);

        vm.stopPrank();
    }

    function testRevertsWithUnapprovedCollateral() public {
        ERC20Mock ran = new ERC20Mock("RAN", "RAN", USER, AMOUNT_COLLATERAL);
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NotAllowedToken.selector);
        engine.depositCollateral(address(ran), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    modifier depositedCollateral() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        engine.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    function testCanDepositCollateralWithoutMinting() public depositedCollateral {
        uint256 userBalance = dsc.balanceOf(USER);
        assertEq(userBalance, 0);
    }

    function testCanDepositCollateralAndGetAccountInfo() public depositedCollateral {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = engine.getAccountInformation(USER);

        uint256 expectedTotalDscMinted = 0;
        uint256 expectedDepositAmount = engine.getTokenAmountFromUsd(weth, collateralValueInUsd);
        uint256 expectedCollateralValueInUsd = engine.getUsdValue(weth, expectedDepositAmount);

        assertEq(totalDscMinted, expectedTotalDscMinted);
        assertEq(AMOUNT_COLLATERAL, expectedDepositAmount);
        assertEq(collateralValueInUsd, expectedCollateralValueInUsd);
    }

    modifier mintDsc() {
        vm.startPrank(USER);
        engine.mintDsc(AMOUNT_DSC_MINTED);
        vm.stopPrank();
        _;
    }

    function testMintDsc() public depositedCollateral mintDsc {
        uint256 actualDscMinted = engine.getAmountOfDscMinted(USER);
        assertEq(AMOUNT_DSC_MINTED, actualDscMinted);
    }

    function testRevertsIfMintAmountIsZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        engine.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, AMOUNT_DSC_MINTED);
        vm.expectRevert(DSCEngine.DSCEngine__NeedMoreThanZero.selector);
        engine.mintDsc(0);
        vm.stopPrank();
    }

    function testUserHealthFactor() public depositedCollateral mintDsc {
        // (uint256 totalDscMinted, uint256 collateralValueInUsd) = engine.getAccountInformation(USER);
        // console.log(totalDscMinted);
        // console.log(collateralValueInUsd);
        // uint256 amountDscMinted = engine.getAmountOfDscMinted(USER);
        uint256 expectedHealthFactor = 5e21;
        uint256 actualHealthFactor = engine.getHealthFactor(USER);
        assertEq(actualHealthFactor, expectedHealthFactor);
    }

    function testUserHealthFactorIsBroken() public depositedCollateral {
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, uint256(1e17)));
        vm.startPrank(USER);
        engine.mintDsc(100000 ether);
        vm.stopPrank();
    }

    modifier depositedCollateralAndMintedDsc() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        engine.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, AMOUNT_DSC_MINTED);
        vm.stopPrank();
        _;
    }

    function testCanMintWithDepositedCollateral() public depositedCollateralAndMintedDsc {
        uint256 userBalance = dsc.balanceOf(USER);
        assertEq(userBalance, AMOUNT_DSC_MINTED);
    }

    function testRevertsIfBurnAmountIsZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        engine.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, AMOUNT_DSC_MINTED);
        vm.expectRevert(DSCEngine.DSCEngine__NeedMoreThanZero.selector);
        engine.burnDsc(0);
        vm.stopPrank();
    }

    function testCantBurnMoreThanUserHas() public {
        vm.prank(USER);
        vm.expectRevert();
        engine.burnDsc(1);
    }

    function testBurnDsc() public depositedCollateral mintDsc {
        uint256 beforeBalance = address(engine).balance;
        uint256 expectedBeforeBalance = 0 ether;
        // ensure user has DSC token to burn
        uint256 userDscBalance = dsc.balanceOf(USER);
        // console.log(userDscBalance);
        assert(userDscBalance >= AMOUNT_DSC_MINTED);
        // approve the contract to burn user token
        vm.startPrank(USER);
        dsc.approve(address(engine), AMOUNT_DSC_MINTED);
        engine.burnDsc(1 ether);
        vm.stopPrank();
        uint256 expectedAfterBalance = address(engine).balance;
        assertEq(beforeBalance, expectedBeforeBalance);
        assertEq(beforeBalance, expectedAfterBalance);
    }

    function testRedeemCollateral() public depositedCollateral mintDsc {
        uint256 actualCollateralAmount = engine.getCollateralBalance(USER, weth);
        uint256 REDEEMED_AMOUNT = 0.01 ether;
        vm.startPrank(USER);
        engine.redeemCollateral(weth, REDEEMED_AMOUNT);
        vm.stopPrank();
        uint256 afterRedeemCollateralAmount = engine.getCollateralBalance(USER, weth);
        // console.log(USER.balance);
        assertEq(actualCollateralAmount - REDEEMED_AMOUNT, afterRedeemCollateralAmount);
        assertEq(AMOUNT_COLLATERAL, actualCollateralAmount);
    }

    function testRedeemCollateralForDsc() public depositedCollateral mintDsc {
        uint256 beforeRedeemDscMinted = engine.getAmountOfDscMinted(USER);
        uint256 beforeRedeemCollateralAmount = engine.getCollateralBalance(USER, weth);

        vm.startPrank(USER);
        dsc.approve(address(engine), AMOUNT_DSC_MINTED);
        engine.redeemCollateralForDsc(weth, 1 ether, 1 ether);
        vm.stopPrank();

        uint256 afterRedeemDscMinted = engine.getAmountOfDscMinted(USER);
        uint256 afterRedeemCollateralAmount = engine.getCollateralBalance(USER, weth);

        assertEq(AMOUNT_DSC_MINTED, beforeRedeemDscMinted);
        assertEq(AMOUNT_COLLATERAL, beforeRedeemCollateralAmount);
        assertEq(beforeRedeemDscMinted - 1 ether, afterRedeemDscMinted);
        assertEq(beforeRedeemCollateralAmount - 1 ether, afterRedeemCollateralAmount);
    }

    ///View and pure functions test///

    function testMinimunHealthFactor() public view {
        uint256 actualMinimumHealthFactor = 1e18;
        assertEq(actualMinimumHealthFactor, engine.getMinimum_Health_Factor());
    }

    function testLiquidationThreshold() public view {
        assertEq(50, engine.getLiquidationThreshold());
    }

    function testLiquidationPrecision() public view {
        assertEq(100, engine.getLiquidationPrecision());
    }

    function testLiquidationBonus() public view {
        assertEq(10, engine.getLiquidationBonus());
    }
}
