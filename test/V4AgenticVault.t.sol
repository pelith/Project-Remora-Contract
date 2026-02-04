// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";

import {V4AgenticVault} from "../src/V4AgenticVault.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IUniversalRouter} from "@uniswap/universal-router/contracts/interfaces/IUniversalRouter.sol";
import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

// ============================================================
// Mock Contracts
// ============================================================

contract MockERC20 is IERC20 {
    string public name;
    string public symbol;
    uint8 public decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (allowance[from][msg.sender] != type(uint256).max) {
            allowance[from][msg.sender] -= amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }
}

contract MockPositionManager {
    uint256 public nextTokenIdValue = 1;
    bool public shouldRevert;
    bytes public lastUnlockData;
    uint256 public lastDeadline;
    uint256 public lastValue;

    function nextTokenId() external view returns (uint256) {
        return nextTokenIdValue;
    }

    function setNextTokenId(uint256 _nextTokenId) external {
        nextTokenIdValue = _nextTokenId;
    }

    function setShouldRevert(bool _shouldRevert) external {
        shouldRevert = _shouldRevert;
    }

    function modifyLiquidities(bytes calldata unlockData, uint256 deadline) external payable {
        require(!shouldRevert, "MockPositionManager: reverted");
        lastUnlockData = unlockData;
        lastDeadline = deadline;
        lastValue = msg.value;
        // Increment tokenId for next mint
        nextTokenIdValue++;
    }
}

contract MockUniversalRouter {
    bool public shouldRevert;
    bytes public lastCommands;
    uint256 public lastInputsLength;
    uint256 public lastDeadline;
    uint256 public lastValue;

    // Swap simulation
    MockERC20 public token0;
    MockERC20 public token1;
    uint256 public swapOutputAmount;

    function setTokens(address _token0, address _token1) external {
        token0 = MockERC20(_token0);
        token1 = MockERC20(_token1);
    }

    function setSwapOutputAmount(uint256 amount) external {
        swapOutputAmount = amount;
    }

    function setShouldRevert(bool _shouldRevert) external {
        shouldRevert = _shouldRevert;
    }

    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable {
        require(!shouldRevert, "MockUniversalRouter: reverted");
        lastCommands = commands;
        lastInputsLength = inputs.length;
        lastDeadline = deadline;
        lastValue = msg.value;

        // Simulate swap by minting output tokens to sender
        if (swapOutputAmount > 0 && address(token1) != address(0)) {
            token1.mint(msg.sender, swapOutputAmount);
        }
    }
}

contract MockPermit2 {
    mapping(address => mapping(address => mapping(address => AllowanceData))) public allowances;

    struct AllowanceData {
        uint160 amount;
        uint48 expiration;
        uint48 nonce;
    }

    function approve(address token, address spender, uint160 amount, uint48 expiration) external {
        allowances[msg.sender][token][spender] = AllowanceData({
            amount: amount,
            expiration: expiration,
            nonce: 0
        });
    }

    function allowance(address user, address token, address spender)
        external
        view
        returns (uint160 amount, uint48 expiration, uint48 nonce)
    {
        AllowanceData memory data = allowances[user][token][spender];
        return (data.amount, data.expiration, data.nonce);
    }
}

// Malicious contract for reentrancy testing
contract ReentrancyAttacker {
    V4AgenticVault public vault;
    bool public attacking;

    constructor(address _vault) {
        vault = V4AgenticVault(payable(_vault));
    }

    receive() external payable {
        if (attacking) {
            attacking = false;
            // Try to reenter withdraw
            vault.withdraw(Currency.wrap(address(0)), 1 ether, address(this));
        }
    }

    function attack() external {
        attacking = true;
        vault.withdraw(Currency.wrap(address(0)), 1 ether, address(this));
    }
}

// ============================================================
// Test Contract
// ============================================================

contract V4AgenticVaultTest is Test {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    V4AgenticVault public vault;
    MockPositionManager public posm;
    MockUniversalRouter public universalRouter;
    MockPermit2 public permit2;
    MockERC20 public token0;
    MockERC20 public token1;

    address public owner = makeAddr("owner");
    address public agent = makeAddr("agent");
    address public user = makeAddr("user");
    address public hooks = address(0);

    int24 public constant TICK_SPACING = 60;
    uint24 public constant FEE = 3000;
    int24 public constant INITIAL_TICK_LOWER = -887220;
    int24 public constant INITIAL_TICK_UPPER = 887220;

    PoolKey public poolKey;

    event AgentUpdated(address indexed newAgent);
    event AgentPaused(bool paused);
    event SwapAllowed(bool allowed);
    event AllowedTickRangeUpdated(int24 tickLower, int24 tickUpper);
    event MaxPositionsKUpdated(uint256 k);
    event PositionAdded(uint256 indexed tokenId, int24 tickLower, int24 tickUpper);
    event PositionRemoved(uint256 indexed tokenId);

    function setUp() public {
        // Deploy mock contracts
        posm = new MockPositionManager();
        universalRouter = new MockUniversalRouter();
        permit2 = new MockPermit2();
        token0 = new MockERC20("Token0", "TKN0");
        token1 = new MockERC20("Token1", "TKN1");

        // Ensure token0 < token1 for proper ordering
        if (address(token0) > address(token1)) {
            (token0, token1) = (token1, token0);
        }

        // Set up pool key
        poolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(hooks)
        });

        // Deploy vault
        vault = new V4AgenticVault(
            owner,
            agent,
            address(posm),
            address(universalRouter),
            address(permit2),
            poolKey,
            INITIAL_TICK_LOWER,
            INITIAL_TICK_UPPER,
            true, // swapAllowed
            0 // maxPositionsK (unlimited)
        );

        // Set up swap simulation
        universalRouter.setTokens(address(token0), address(token1));

        // Fund the vault for testing
        token0.mint(address(vault), 1000 ether);
        token1.mint(address(vault), 1000 ether);
        vm.deal(address(vault), 100 ether);
    }

    // ============================================================
    // Constructor Tests
    // ============================================================

    function test_Constructor_Success() public view {
        assertEq(vault.owner(), owner);
        assertEq(vault.agent(), agent);
        assertEq(address(vault.posm()), address(posm));
        assertEq(address(vault.universalRouter()), address(universalRouter));
        assertEq(address(vault.permit2()), address(permit2));
        assertEq(Currency.unwrap(vault.currency0()), address(token0));
        assertEq(Currency.unwrap(vault.currency1()), address(token1));
        assertEq(vault.fee(), FEE);
        assertEq(vault.tickSpacing(), TICK_SPACING);
        assertEq(vault.hooks(), hooks);
        assertEq(vault.allowedTickLower(), INITIAL_TICK_LOWER);
        assertEq(vault.allowedTickUpper(), INITIAL_TICK_UPPER);
        assertEq(vault.swapAllowed(), true);
        assertEq(vault.maxPositionsK(), 0);
        assertEq(vault.agentPaused(), false);
    }

    function test_Constructor_RevertBadPosm() public {
        vm.expectRevert("bad addr");
        new V4AgenticVault(
            owner,
            agent,
            address(0), // bad posm
            address(universalRouter),
            address(permit2),
            poolKey,
            INITIAL_TICK_LOWER,
            INITIAL_TICK_UPPER,
            true,
            0
        );
    }

    function test_Constructor_RevertBadUniversalRouter() public {
        vm.expectRevert("bad addr");
        new V4AgenticVault(
            owner,
            agent,
            address(posm),
            address(0), // bad universalRouter
            address(permit2),
            poolKey,
            INITIAL_TICK_LOWER,
            INITIAL_TICK_UPPER,
            true,
            0
        );
    }

    function test_Constructor_RevertBadPermit2() public {
        vm.expectRevert("bad addr");
        new V4AgenticVault(
            owner,
            agent,
            address(posm),
            address(universalRouter),
            address(0), // bad permit2
            poolKey,
            INITIAL_TICK_LOWER,
            INITIAL_TICK_UPPER,
            true,
            0
        );
    }

    function test_Constructor_RevertBadTicks() public {
        vm.expectRevert("bad ticks");
        new V4AgenticVault(
            owner,
            agent,
            address(posm),
            address(universalRouter),
            address(permit2),
            poolKey,
            100, // tickLower >= tickUpper
            100,
            true,
            0
        );
    }

    function test_Constructor_RevertTickLowerGreaterThanUpper() public {
        vm.expectRevert("bad ticks");
        new V4AgenticVault(
            owner,
            agent,
            address(posm),
            address(universalRouter),
            address(permit2),
            poolKey,
            100, // tickLower > tickUpper
            -100,
            true,
            0
        );
    }

    function test_Constructor_WithZeroAgent() public {
        V4AgenticVault vaultWithZeroAgent = new V4AgenticVault(
            owner,
            address(0), // zero agent
            address(posm),
            address(universalRouter),
            address(permit2),
            poolKey,
            INITIAL_TICK_LOWER,
            INITIAL_TICK_UPPER,
            true,
            0
        );
        assertEq(vaultWithZeroAgent.agent(), address(0));
    }

    // ============================================================
    // Owner Configuration Tests
    // ============================================================

    function test_SetAgent() public {
        address newAgent = makeAddr("newAgent");

        vm.expectEmit(true, false, false, false);
        emit AgentUpdated(newAgent);

        vm.prank(owner);
        vault.setAgent(newAgent);

        assertEq(vault.agent(), newAgent);
    }

    function test_SetAgent_ToZero() public {
        vm.prank(owner);
        vault.setAgent(address(0));
        assertEq(vault.agent(), address(0));
    }

    function test_SetAgent_RevertNotOwner() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        vault.setAgent(user);
    }

    function test_SetAgentPaused() public {
        vm.expectEmit(false, false, false, true);
        emit AgentPaused(true);

        vm.prank(owner);
        vault.setAgentPaused(true);

        assertEq(vault.agentPaused(), true);
    }

    function test_SetAgentPaused_Unpause() public {
        vm.prank(owner);
        vault.setAgentPaused(true);

        vm.expectEmit(false, false, false, true);
        emit AgentPaused(false);

        vm.prank(owner);
        vault.setAgentPaused(false);

        assertEq(vault.agentPaused(), false);
    }

    function test_SetAgentPaused_RevertNotOwner() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        vault.setAgentPaused(true);
    }

    function test_SetSwapAllowed() public {
        vm.expectEmit(false, false, false, true);
        emit SwapAllowed(false);

        vm.prank(owner);
        vault.setSwapAllowed(false);

        assertEq(vault.swapAllowed(), false);
    }

    function test_SetSwapAllowed_RevertNotOwner() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        vault.setSwapAllowed(false);
    }

    function test_SetAllowedTickRange() public {
        int24 newTickLower = -1000;
        int24 newTickUpper = 1000;

        vm.expectEmit(false, false, false, true);
        emit AllowedTickRangeUpdated(newTickLower, newTickUpper);

        vm.prank(owner);
        vault.setAllowedTickRange(newTickLower, newTickUpper);

        assertEq(vault.allowedTickLower(), newTickLower);
        assertEq(vault.allowedTickUpper(), newTickUpper);
    }

    function test_SetAllowedTickRange_RevertBadTicks() public {
        vm.prank(owner);
        vm.expectRevert("bad ticks");
        vault.setAllowedTickRange(100, 100);
    }

    function test_SetAllowedTickRange_RevertTickLowerGreaterThanUpper() public {
        vm.prank(owner);
        vm.expectRevert("bad ticks");
        vault.setAllowedTickRange(100, -100);
    }

    function test_SetAllowedTickRange_RevertNotOwner() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        vault.setAllowedTickRange(-1000, 1000);
    }

    function test_SetMaxPositionsK() public {
        uint256 newK = 5;

        vm.expectEmit(false, false, false, true);
        emit MaxPositionsKUpdated(newK);

        vm.prank(owner);
        vault.setMaxPositionsK(newK);

        assertEq(vault.maxPositionsK(), newK);
    }

    function test_SetMaxPositionsK_ToZero() public {
        vm.prank(owner);
        vault.setMaxPositionsK(5);

        vm.prank(owner);
        vault.setMaxPositionsK(0);

        assertEq(vault.maxPositionsK(), 0);
    }

    function test_SetMaxPositionsK_RevertNotOwner() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        vault.setMaxPositionsK(5);
    }

    function test_ApproveTokenWithPermit2() public {
        uint160 amount = type(uint160).max;
        uint48 expiration = uint48(block.timestamp + 1 days);

        vm.prank(owner);
        vault.approveTokenWithPermit2(
            Currency.wrap(address(token0)),
            address(posm),
            amount,
            expiration
        );

        // Check permit2 allowance was set
        (uint160 allowedAmount, uint48 allowedExpiration,) = permit2.allowance(
            address(vault),
            address(token0),
            address(posm)
        );
        assertEq(allowedAmount, amount);
        assertEq(allowedExpiration, expiration);

        // Check ERC20 approval to permit2
        assertEq(token0.allowance(address(vault), address(permit2)), type(uint256).max);
    }

    function test_ApproveTokenWithPermit2_UniversalRouter() public {
        uint160 amount = type(uint160).max;
        uint48 expiration = uint48(block.timestamp + 1 days);

        vm.prank(owner);
        vault.approveTokenWithPermit2(
            Currency.wrap(address(token0)),
            address(universalRouter),
            amount,
            expiration
        );

        (uint160 allowedAmount,,) = permit2.allowance(
            address(vault),
            address(token0),
            address(universalRouter)
        );
        assertEq(allowedAmount, amount);
    }

    function test_ApproveTokenWithPermit2_RevertBadSpender() public {
        vm.prank(owner);
        vm.expectRevert("spender not allowed");
        vault.approveTokenWithPermit2(
            Currency.wrap(address(token0)),
            user,
            type(uint160).max,
            uint48(block.timestamp + 1 days)
        );
    }

    function test_ApproveTokenWithPermit2_RevertNativeETH() public {
        vm.prank(owner);
        vm.expectRevert("native ETH no permit2");
        vault.approveTokenWithPermit2(
            Currency.wrap(address(0)),
            address(posm),
            type(uint160).max,
            uint48(block.timestamp + 1 days)
        );
    }

    function test_ApproveTokenWithPermit2_RevertNotOwner() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        vault.approveTokenWithPermit2(
            Currency.wrap(address(token0)),
            address(posm),
            type(uint160).max,
            uint48(block.timestamp + 1 days)
        );
    }

    // ============================================================
    // Receive ETH Tests
    // ============================================================

    function test_Receive_ETH() public {
        uint256 balanceBefore = address(vault).balance;

        vm.deal(user, 1 ether);
        vm.prank(user);
        (bool success,) = address(vault).call{value: 1 ether}("");

        assertTrue(success);
        assertEq(address(vault).balance, balanceBefore + 1 ether);
    }

    // ============================================================
    // Withdraw Tests
    // ============================================================

    function test_Withdraw_ETH() public {
        uint256 withdrawAmount = 1 ether;
        uint256 userBalanceBefore = user.balance;

        vm.prank(owner);
        vault.withdraw(Currency.wrap(address(0)), withdrawAmount, user);

        assertEq(user.balance, userBalanceBefore + withdrawAmount);
    }

    function test_Withdraw_ERC20() public {
        uint256 withdrawAmount = 100 ether;
        uint256 userBalanceBefore = token0.balanceOf(user);

        vm.prank(owner);
        vault.withdraw(Currency.wrap(address(token0)), withdrawAmount, user);

        assertEq(token0.balanceOf(user), userBalanceBefore + withdrawAmount);
    }

    function test_Withdraw_RevertBadTo() public {
        vm.prank(owner);
        vm.expectRevert("bad to");
        vault.withdraw(Currency.wrap(address(0)), 1 ether, address(0));
    }

    function test_Withdraw_RevertNotOwner() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        vault.withdraw(Currency.wrap(address(0)), 1 ether, user);
    }

    function test_Withdraw_ETH_RevertTransferFailed() public {
        // Deploy a contract that rejects ETH
        RejectETH rejectETH = new RejectETH();

        vm.prank(owner);
        vm.expectRevert("eth transfer failed");
        vault.withdraw(Currency.wrap(address(0)), 1 ether, address(rejectETH));
    }

    // ============================================================
    // PauseAndExitAll Tests
    // ============================================================

    function test_PauseAndExitAll_NoPositions() public {
        vm.expectEmit(false, false, false, true);
        emit AgentPaused(true);

        vm.prank(owner);
        vault.pauseAndExitAll(block.timestamp + 1 hours);

        assertTrue(vault.agentPaused());
        assertEq(vault.positionsLength(), 0);
    }

    function test_PauseAndExitAll_WithPositions() public {
        // First mint some positions
        _mintTestPosition(-600, 600);
        _mintTestPosition(-1200, 1200);

        assertEq(vault.positionsLength(), 2);

        vm.prank(owner);
        vault.pauseAndExitAll(block.timestamp + 1 hours);

        assertTrue(vault.agentPaused());
        assertEq(vault.positionsLength(), 0);
    }

    function test_PauseAndExitAll_RevertNotOwner() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        vault.pauseAndExitAll(block.timestamp + 1 hours);
    }

    // ============================================================
    // MintPosition Tests
    // ============================================================

    function test_MintPosition() public {
        int24 tickLower = -600;
        int24 tickUpper = 600;
        uint256 liquidity = 1000e18;
        uint128 amount0Max = 100e18;
        uint128 amount1Max = 100e18;
        uint256 deadline = block.timestamp + 1 hours;
        uint256 expectedTokenId = posm.nextTokenId();

        vm.expectEmit(true, false, false, true);
        emit PositionAdded(expectedTokenId, tickLower, tickUpper);

        vm.prank(agent);
        uint256 tokenId = vault.mintPosition(
            tickLower,
            tickUpper,
            liquidity,
            amount0Max,
            amount1Max,
            deadline
        );

        assertEq(tokenId, expectedTokenId);
        assertTrue(vault.isManagedPosition(tokenId));
        assertEq(vault.positionTickLower(tokenId), tickLower);
        assertEq(vault.positionTickUpper(tokenId), tickUpper);
        assertEq(vault.positionsLength(), 1);
        assertEq(vault.positionIds(0), tokenId);
    }

    function test_MintPosition_WithNativeETH() public {
        // Create vault with native ETH as currency0
        PoolKey memory ethPoolKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(token1)),
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(hooks)
        });

        V4AgenticVault ethVault = new V4AgenticVault(
            owner,
            agent,
            address(posm),
            address(universalRouter),
            address(permit2),
            ethPoolKey,
            INITIAL_TICK_LOWER,
            INITIAL_TICK_UPPER,
            true,
            0
        );

        // Fund vault with ETH
        vm.deal(address(ethVault), 100 ether);

        vm.prank(agent);
        uint256 tokenId = ethVault.mintPosition(
            -600,
            600,
            1000e18,
            10e18,
            10e18,
            block.timestamp + 1 hours
        );

        assertTrue(ethVault.isManagedPosition(tokenId));
        // Check that value was sent to posm
        assertEq(posm.lastValue(), 10e18);
    }

    function test_MintPosition_RevertNotAgent() public {
        vm.prank(user);
        vm.expectRevert("not agent");
        vault.mintPosition(-600, 600, 1000e18, 100e18, 100e18, block.timestamp + 1 hours);
    }

    function test_MintPosition_RevertAgentPaused() public {
        vm.prank(owner);
        vault.setAgentPaused(true);

        vm.prank(agent);
        vm.expectRevert("agent paused");
        vault.mintPosition(-600, 600, 1000e18, 100e18, 100e18, block.timestamp + 1 hours);
    }

    function test_MintPosition_RevertTickOrder() public {
        vm.prank(agent);
        vm.expectRevert("tick order");
        vault.mintPosition(600, -600, 1000e18, 100e18, 100e18, block.timestamp + 1 hours);
    }

    function test_MintPosition_RevertTickLowerTooLow() public {
        vm.prank(owner);
        vault.setAllowedTickRange(-1000, 1000);

        vm.prank(agent);
        vm.expectRevert("tickLower too low");
        vault.mintPosition(-1200, 600, 1000e18, 100e18, 100e18, block.timestamp + 1 hours);
    }

    function test_MintPosition_RevertTickUpperTooHigh() public {
        vm.prank(owner);
        vault.setAllowedTickRange(-1000, 1000);

        vm.prank(agent);
        vm.expectRevert("tickUpper too high");
        vault.mintPosition(-600, 1200, 1000e18, 100e18, 100e18, block.timestamp + 1 hours);
    }

    function test_MintPosition_RevertTickLowerNotMultiple() public {
        vm.prank(agent);
        vm.expectRevert("tickLower !multiple");
        vault.mintPosition(-601, 600, 1000e18, 100e18, 100e18, block.timestamp + 1 hours);
    }

    function test_MintPosition_RevertTickUpperNotMultiple() public {
        vm.prank(agent);
        vm.expectRevert("tickUpper !multiple");
        vault.mintPosition(-600, 601, 1000e18, 100e18, 100e18, block.timestamp + 1 hours);
    }

    function test_MintPosition_RevertMaxPositionsReached() public {
        vm.prank(owner);
        vault.setMaxPositionsK(2);

        // Mint 2 positions
        _mintTestPosition(-600, 600);
        _mintTestPosition(-1200, 1200);

        // Try to mint a 3rd position
        vm.prank(agent);
        vm.expectRevert("max positions reached");
        vault.mintPosition(-1800, 1800, 1000e18, 100e18, 100e18, block.timestamp + 1 hours);
    }

    function test_MintPosition_KEqualsZeroAllowsUnlimited() public {
        // K=0 should allow unlimited positions
        for (uint256 i = 0; i < 10; i++) {
            int24 offset = int24(int256(i * 120));
            _mintTestPosition(-600 - offset, 600 + offset);
        }

        assertEq(vault.positionsLength(), 10);
    }

    // ============================================================
    // IncreaseLiquidity Tests
    // ============================================================

    function test_IncreaseLiquidity() public {
        uint256 tokenId = _mintTestPosition(-600, 600);

        vm.prank(agent);
        vault.increaseLiquidity(
            tokenId,
            500e18,
            50e18,
            50e18,
            block.timestamp + 1 hours
        );

        // Verify posm was called
        assertEq(posm.lastDeadline(), block.timestamp + 1 hours);
    }

    function test_IncreaseLiquidity_WithNativeETH() public {
        // Create vault with native ETH
        PoolKey memory ethPoolKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(token1)),
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(hooks)
        });

        V4AgenticVault ethVault = new V4AgenticVault(
            owner,
            agent,
            address(posm),
            address(universalRouter),
            address(permit2),
            ethPoolKey,
            INITIAL_TICK_LOWER,
            INITIAL_TICK_UPPER,
            true,
            0
        );

        vm.deal(address(ethVault), 100 ether);

        // Mint position first
        vm.prank(agent);
        uint256 tokenId = ethVault.mintPosition(
            -600, 600, 1000e18, 10e18, 10e18, block.timestamp + 1 hours
        );

        // Increase liquidity
        vm.prank(agent);
        ethVault.increaseLiquidity(
            tokenId,
            500e18,
            5e18,
            5e18,
            block.timestamp + 1 hours
        );

        // Check ETH was sent
        assertEq(posm.lastValue(), 5e18);
    }

    function test_IncreaseLiquidity_RevertUnknownTokenId() public {
        vm.prank(agent);
        vm.expectRevert("unknown tokenId");
        vault.increaseLiquidity(999, 500e18, 50e18, 50e18, block.timestamp + 1 hours);
    }

    function test_IncreaseLiquidity_RevertNotAgent() public {
        uint256 tokenId = _mintTestPosition(-600, 600);

        vm.prank(user);
        vm.expectRevert("not agent");
        vault.increaseLiquidity(tokenId, 500e18, 50e18, 50e18, block.timestamp + 1 hours);
    }

    function test_IncreaseLiquidity_RevertAgentPaused() public {
        uint256 tokenId = _mintTestPosition(-600, 600);

        vm.prank(owner);
        vault.setAgentPaused(true);

        vm.prank(agent);
        vm.expectRevert("agent paused");
        vault.increaseLiquidity(tokenId, 500e18, 50e18, 50e18, block.timestamp + 1 hours);
    }

    function test_IncreaseLiquidity_RevertPositionOutOfBounds() public {
        // Mint position with wide range
        uint256 tokenId = _mintTestPosition(-6000, 6000);

        // Narrow the allowed range
        vm.prank(owner);
        vault.setAllowedTickRange(-1000, 1000);

        // Try to increase - should fail because position is out of bounds
        vm.prank(agent);
        vm.expectRevert("position out of bounds");
        vault.increaseLiquidity(tokenId, 500e18, 50e18, 50e18, block.timestamp + 1 hours);
    }

    // ============================================================
    // DecreaseLiquidityToVault Tests
    // ============================================================

    function test_DecreaseLiquidityToVault() public {
        uint256 tokenId = _mintTestPosition(-600, 600);

        vm.prank(agent);
        vault.decreaseLiquidityToVault(
            tokenId,
            500e18,
            10e18,
            10e18,
            block.timestamp + 1 hours
        );

        // Position should still exist
        assertTrue(vault.isManagedPosition(tokenId));
        assertEq(posm.lastDeadline(), block.timestamp + 1 hours);
    }

    function test_DecreaseLiquidityToVault_AllowedEvenIfOutOfBounds() public {
        uint256 tokenId = _mintTestPosition(-6000, 6000);

        // Narrow the allowed range
        vm.prank(owner);
        vault.setAllowedTickRange(-1000, 1000);

        // Decrease should still work even though position is out of bounds
        vm.prank(agent);
        vault.decreaseLiquidityToVault(
            tokenId,
            500e18,
            10e18,
            10e18,
            block.timestamp + 1 hours
        );

        assertTrue(vault.isManagedPosition(tokenId));
    }

    function test_DecreaseLiquidityToVault_RevertUnknownTokenId() public {
        vm.prank(agent);
        vm.expectRevert("unknown tokenId");
        vault.decreaseLiquidityToVault(999, 500e18, 10e18, 10e18, block.timestamp + 1 hours);
    }

    function test_DecreaseLiquidityToVault_RevertNotAgent() public {
        uint256 tokenId = _mintTestPosition(-600, 600);

        vm.prank(user);
        vm.expectRevert("not agent");
        vault.decreaseLiquidityToVault(tokenId, 500e18, 10e18, 10e18, block.timestamp + 1 hours);
    }

    function test_DecreaseLiquidityToVault_RevertAgentPaused() public {
        uint256 tokenId = _mintTestPosition(-600, 600);

        vm.prank(owner);
        vault.setAgentPaused(true);

        vm.prank(agent);
        vm.expectRevert("agent paused");
        vault.decreaseLiquidityToVault(tokenId, 500e18, 10e18, 10e18, block.timestamp + 1 hours);
    }

    // ============================================================
    // CollectFeesToVault Tests
    // ============================================================

    function test_CollectFeesToVault() public {
        uint256 tokenId = _mintTestPosition(-600, 600);

        vm.prank(agent);
        vault.collectFeesToVault(
            tokenId,
            0,
            0,
            block.timestamp + 1 hours
        );

        assertTrue(vault.isManagedPosition(tokenId));
        assertEq(posm.lastDeadline(), block.timestamp + 1 hours);
    }

    function test_CollectFeesToVault_AllowedEvenIfOutOfBounds() public {
        uint256 tokenId = _mintTestPosition(-6000, 6000);

        vm.prank(owner);
        vault.setAllowedTickRange(-1000, 1000);

        // Collect should work even though position is out of bounds
        vm.prank(agent);
        vault.collectFeesToVault(
            tokenId,
            0,
            0,
            block.timestamp + 1 hours
        );

        assertTrue(vault.isManagedPosition(tokenId));
    }

    function test_CollectFeesToVault_RevertUnknownTokenId() public {
        vm.prank(agent);
        vm.expectRevert("unknown tokenId");
        vault.collectFeesToVault(999, 0, 0, block.timestamp + 1 hours);
    }

    function test_CollectFeesToVault_RevertNotAgent() public {
        uint256 tokenId = _mintTestPosition(-600, 600);

        vm.prank(user);
        vm.expectRevert("not agent");
        vault.collectFeesToVault(tokenId, 0, 0, block.timestamp + 1 hours);
    }

    function test_CollectFeesToVault_RevertAgentPaused() public {
        uint256 tokenId = _mintTestPosition(-600, 600);

        vm.prank(owner);
        vault.setAgentPaused(true);

        vm.prank(agent);
        vm.expectRevert("agent paused");
        vault.collectFeesToVault(tokenId, 0, 0, block.timestamp + 1 hours);
    }

    // ============================================================
    // BurnPositionToVault Tests
    // ============================================================

    function test_BurnPositionToVault() public {
        uint256 tokenId = _mintTestPosition(-600, 600);

        vm.expectEmit(true, false, false, false);
        emit PositionRemoved(tokenId);

        vm.prank(agent);
        vault.burnPositionToVault(
            tokenId,
            0,
            0,
            block.timestamp + 1 hours
        );

        assertFalse(vault.isManagedPosition(tokenId));
        assertEq(vault.positionsLength(), 0);
    }

    function test_BurnPositionToVault_AllowedEvenIfOutOfBounds() public {
        uint256 tokenId = _mintTestPosition(-6000, 6000);

        vm.prank(owner);
        vault.setAllowedTickRange(-1000, 1000);

        // Burn should work even though position is out of bounds
        vm.prank(agent);
        vault.burnPositionToVault(
            tokenId,
            0,
            0,
            block.timestamp + 1 hours
        );

        assertFalse(vault.isManagedPosition(tokenId));
    }

    function test_BurnPositionToVault_MultiplePositions_RemoveFirst() public {
        uint256 tokenId1 = _mintTestPosition(-600, 600);
        uint256 tokenId2 = _mintTestPosition(-1200, 1200);
        uint256 tokenId3 = _mintTestPosition(-1800, 1800);

        assertEq(vault.positionsLength(), 3);

        // Burn first position
        vm.prank(agent);
        vault.burnPositionToVault(tokenId1, 0, 0, block.timestamp + 1 hours);

        assertEq(vault.positionsLength(), 2);
        assertFalse(vault.isManagedPosition(tokenId1));
        assertTrue(vault.isManagedPosition(tokenId2));
        assertTrue(vault.isManagedPosition(tokenId3));

        // Check swap-and-pop: tokenId3 should now be at index 0
        assertEq(vault.positionIds(0), tokenId3);
        assertEq(vault.positionIds(1), tokenId2);
    }

    function test_BurnPositionToVault_MultiplePositions_RemoveMiddle() public {
        uint256 tokenId1 = _mintTestPosition(-600, 600);
        uint256 tokenId2 = _mintTestPosition(-1200, 1200);
        uint256 tokenId3 = _mintTestPosition(-1800, 1800);

        // Burn middle position
        vm.prank(agent);
        vault.burnPositionToVault(tokenId2, 0, 0, block.timestamp + 1 hours);

        assertEq(vault.positionsLength(), 2);
        assertFalse(vault.isManagedPosition(tokenId2));

        // Check swap-and-pop: tokenId3 should now be at index 1
        assertEq(vault.positionIds(0), tokenId1);
        assertEq(vault.positionIds(1), tokenId3);
    }

    function test_BurnPositionToVault_MultiplePositions_RemoveLast() public {
        uint256 tokenId1 = _mintTestPosition(-600, 600);
        uint256 tokenId2 = _mintTestPosition(-1200, 1200);
        uint256 tokenId3 = _mintTestPosition(-1800, 1800);

        // Burn last position
        vm.prank(agent);
        vault.burnPositionToVault(tokenId3, 0, 0, block.timestamp + 1 hours);

        assertEq(vault.positionsLength(), 2);
        assertFalse(vault.isManagedPosition(tokenId3));

        // Order should be preserved
        assertEq(vault.positionIds(0), tokenId1);
        assertEq(vault.positionIds(1), tokenId2);
    }

    function test_BurnPositionToVault_RevertUnknownTokenId() public {
        vm.prank(agent);
        vm.expectRevert("unknown tokenId");
        vault.burnPositionToVault(999, 0, 0, block.timestamp + 1 hours);
    }

    function test_BurnPositionToVault_RevertNotAgent() public {
        uint256 tokenId = _mintTestPosition(-600, 600);

        vm.prank(user);
        vm.expectRevert("not agent");
        vault.burnPositionToVault(tokenId, 0, 0, block.timestamp + 1 hours);
    }

    function test_BurnPositionToVault_RevertAgentPaused() public {
        uint256 tokenId = _mintTestPosition(-600, 600);

        vm.prank(owner);
        vault.setAgentPaused(true);

        vm.prank(agent);
        vm.expectRevert("agent paused");
        vault.burnPositionToVault(tokenId, 0, 0, block.timestamp + 1 hours);
    }

    // ============================================================
    // SwapExactInputSingle Tests
    // ============================================================

    function test_SwapExactInputSingle_ZeroForOne() public {
        uint128 amountIn = 10e18;
        uint128 minAmountOut = 9e18;
        uint256 expectedOut = 9.5e18;

        universalRouter.setSwapOutputAmount(expectedOut);

        vm.prank(agent);
        uint256 amountOut = vault.swapExactInputSingle(
            true, // zeroForOne
            amountIn,
            minAmountOut,
            block.timestamp + 1 hours
        );

        assertEq(amountOut, expectedOut);
        assertEq(universalRouter.lastDeadline(), block.timestamp + 1 hours);
    }

    function test_SwapExactInputSingle_OneForZero() public {
        uint128 amountIn = 10e18;
        uint128 minAmountOut = 9e18;
        uint256 expectedOut = 9.5e18;

        // For oneForZero, output is token0
        universalRouter.setTokens(address(token1), address(token0));
        universalRouter.setSwapOutputAmount(expectedOut);

        vm.prank(agent);
        uint256 amountOut = vault.swapExactInputSingle(
            false, // oneForZero
            amountIn,
            minAmountOut,
            block.timestamp + 1 hours
        );

        assertEq(amountOut, expectedOut);
    }

    function test_SwapExactInputSingle_WithNativeETH() public {
        // Create vault with native ETH
        PoolKey memory ethPoolKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(token1)),
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(hooks)
        });

        V4AgenticVault ethVault = new V4AgenticVault(
            owner,
            agent,
            address(posm),
            address(universalRouter),
            address(permit2),
            ethPoolKey,
            INITIAL_TICK_LOWER,
            INITIAL_TICK_UPPER,
            true,
            0
        );

        vm.deal(address(ethVault), 100 ether);
        token1.mint(address(ethVault), 100 ether);

        universalRouter.setSwapOutputAmount(9e18);

        vm.prank(agent);
        ethVault.swapExactInputSingle(
            true, // zeroForOne (ETH -> token1)
            10e18,
            9e18,
            block.timestamp + 1 hours
        );

        // Check ETH was sent as value
        assertEq(universalRouter.lastValue(), 10e18);
    }

    function test_SwapExactInputSingle_RevertSwapDisabled() public {
        vm.prank(owner);
        vault.setSwapAllowed(false);

        vm.prank(agent);
        vm.expectRevert("swap disabled");
        vault.swapExactInputSingle(true, 10e18, 9e18, block.timestamp + 1 hours);
    }

    function test_SwapExactInputSingle_RevertInsufficientOut() public {
        universalRouter.setSwapOutputAmount(8e18); // Less than minAmountOut

        vm.prank(agent);
        vm.expectRevert("insufficient out");
        vault.swapExactInputSingle(true, 10e18, 9e18, block.timestamp + 1 hours);
    }

    function test_SwapExactInputSingle_RevertNotAgent() public {
        vm.prank(user);
        vm.expectRevert("not agent");
        vault.swapExactInputSingle(true, 10e18, 9e18, block.timestamp + 1 hours);
    }

    function test_SwapExactInputSingle_RevertAgentPaused() public {
        vm.prank(owner);
        vault.setAgentPaused(true);

        vm.prank(agent);
        vm.expectRevert("agent paused");
        vault.swapExactInputSingle(true, 10e18, 9e18, block.timestamp + 1 hours);
    }

    // ============================================================
    // View Function Tests
    // ============================================================

    function test_GetPoolKey() public view {
        PoolKey memory key = vault.getPoolKey();

        assertEq(Currency.unwrap(key.currency0), address(token0));
        assertEq(Currency.unwrap(key.currency1), address(token1));
        assertEq(key.fee, FEE);
        assertEq(key.tickSpacing, TICK_SPACING);
        assertEq(address(key.hooks), hooks);
    }

    function test_PositionsLength() public {
        assertEq(vault.positionsLength(), 0);

        _mintTestPosition(-600, 600);
        assertEq(vault.positionsLength(), 1);

        _mintTestPosition(-1200, 1200);
        assertEq(vault.positionsLength(), 2);
    }

    // ============================================================
    // ERC721 Receiver Tests
    // ============================================================

    function test_OnERC721Received() public view {
        bytes4 selector = vault.onERC721Received(address(0), address(0), 0, "");
        assertEq(selector, bytes4(keccak256("onERC721Received(address,address,uint256,bytes)")));
    }

    // ============================================================
    // Edge Case Tests
    // ============================================================

    function test_TickBoundaryUpdate_ExistingPositionCanDecreaseButNotIncrease() public {
        // Mint position with wide range
        uint256 tokenId = _mintTestPosition(-6000, 6000);

        // Narrow the allowed range
        vm.prank(owner);
        vault.setAllowedTickRange(-1000, 1000);

        // Increase should fail
        vm.prank(agent);
        vm.expectRevert("position out of bounds");
        vault.increaseLiquidity(tokenId, 500e18, 50e18, 50e18, block.timestamp + 1 hours);

        // But decrease, collect, and burn should work
        vm.prank(agent);
        vault.decreaseLiquidityToVault(tokenId, 100e18, 0, 0, block.timestamp + 1 hours);

        vm.prank(agent);
        vault.collectFeesToVault(tokenId, 0, 0, block.timestamp + 1 hours);

        vm.prank(agent);
        vault.burnPositionToVault(tokenId, 0, 0, block.timestamp + 1 hours);
    }

    function test_TickBoundaryUpdate_NewMintMustRespectNewBounds() public {
        // Narrow the allowed range
        vm.prank(owner);
        vault.setAllowedTickRange(-1000, 1000);

        // Mint with old wide range should fail
        vm.prank(agent);
        vm.expectRevert("tickLower too low");
        vault.mintPosition(-6000, 6000, 1000e18, 100e18, 100e18, block.timestamp + 1 hours);

        // Mint within new range should work
        _mintTestPosition(-600, 600);
        assertEq(vault.positionsLength(), 1);
    }

    function test_MaxPositionsK_CanLowerBelowCurrentCount() public {
        // Mint 3 positions
        _mintTestPosition(-600, 600);
        _mintTestPosition(-1200, 1200);
        _mintTestPosition(-1800, 1800);

        // Set K to 2 (below current count of 3)
        vm.prank(owner);
        vault.setMaxPositionsK(2);

        // Existing positions still work
        assertEq(vault.positionsLength(), 3);

        // But new mints are blocked
        vm.prank(agent);
        vm.expectRevert("max positions reached");
        vault.mintPosition(-2400, 2400, 1000e18, 100e18, 100e18, block.timestamp + 1 hours);
    }

    function test_PositionArrayManagement_BurnAllPositions() public {
        uint256 tokenId1 = _mintTestPosition(-600, 600);
        uint256 tokenId2 = _mintTestPosition(-1200, 1200);
        uint256 tokenId3 = _mintTestPosition(-1800, 1800);

        // Burn all in random order
        vm.prank(agent);
        vault.burnPositionToVault(tokenId2, 0, 0, block.timestamp + 1 hours);

        vm.prank(agent);
        vault.burnPositionToVault(tokenId1, 0, 0, block.timestamp + 1 hours);

        vm.prank(agent);
        vault.burnPositionToVault(tokenId3, 0, 0, block.timestamp + 1 hours);

        assertEq(vault.positionsLength(), 0);
        assertFalse(vault.isManagedPosition(tokenId1));
        assertFalse(vault.isManagedPosition(tokenId2));
        assertFalse(vault.isManagedPosition(tokenId3));
    }

    function test_TickSpacingZero() public {
        // Create pool key with zero tick spacing
        PoolKey memory badPoolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: FEE,
            tickSpacing: 0,
            hooks: IHooks(hooks)
        });

        V4AgenticVault badVault = new V4AgenticVault(
            owner,
            agent,
            address(posm),
            address(universalRouter),
            address(permit2),
            badPoolKey,
            INITIAL_TICK_LOWER,
            INITIAL_TICK_UPPER,
            true,
            0
        );

        vm.prank(agent);
        vm.expectRevert("bad tickSpacing");
        badVault.mintPosition(-600, 600, 1000e18, 100e18, 100e18, block.timestamp + 1 hours);
    }

    function test_AgentZeroAddress_BlocksAllOperations() public {
        vm.prank(owner);
        vault.setAgent(address(0));

        // Any regular user cannot act as agent
        vm.prank(user);
        vm.expectRevert("not agent");
        vault.mintPosition(-600, 600, 1000e18, 100e18, 100e18, block.timestamp + 1 hours);

        // Even the old agent cannot act
        vm.prank(agent);
        vm.expectRevert("not agent");
        vault.mintPosition(-600, 600, 1000e18, 100e18, 100e18, block.timestamp + 1 hours);
    }

    function test_ResumeAfterPause() public {
        _mintTestPosition(-600, 600);

        // Pause
        vm.prank(owner);
        vault.setAgentPaused(true);

        // Operations fail
        vm.prank(agent);
        vm.expectRevert("agent paused");
        vault.mintPosition(-1200, 1200, 1000e18, 100e18, 100e18, block.timestamp + 1 hours);

        // Unpause
        vm.prank(owner);
        vault.setAgentPaused(false);

        // Operations work again
        _mintTestPosition(-1200, 1200);
        assertEq(vault.positionsLength(), 2);
    }

    function test_SwapExactInputSingle_ExactMinAmountOut() public {
        uint128 amountIn = 10e18;
        uint128 minAmountOut = 9e18;

        // Set output exactly equal to minimum
        universalRouter.setSwapOutputAmount(minAmountOut);

        vm.prank(agent);
        uint256 amountOut = vault.swapExactInputSingle(
            true,
            amountIn,
            minAmountOut,
            block.timestamp + 1 hours
        );

        assertEq(amountOut, minAmountOut);
    }

    function test_MultipleMintBurnCycles() public {
        // Cycle 1
        uint256 tokenId1 = _mintTestPosition(-600, 600);
        vm.prank(agent);
        vault.burnPositionToVault(tokenId1, 0, 0, block.timestamp + 1 hours);

        // Cycle 2
        uint256 tokenId2 = _mintTestPosition(-600, 600);
        uint256 tokenId3 = _mintTestPosition(-1200, 1200);
        vm.prank(agent);
        vault.burnPositionToVault(tokenId2, 0, 0, block.timestamp + 1 hours);

        // Cycle 3
        uint256 tokenId4 = _mintTestPosition(-1800, 1800);

        assertEq(vault.positionsLength(), 2);
        assertTrue(vault.isManagedPosition(tokenId3));
        assertTrue(vault.isManagedPosition(tokenId4));
        assertFalse(vault.isManagedPosition(tokenId1));
        assertFalse(vault.isManagedPosition(tokenId2));
    }

    // ============================================================
    // Additional Branch Coverage Tests
    // ============================================================

    function test_MintPosition_TicksExactlyAtBounds() public {
        // Set narrow allowed range
        vm.prank(owner);
        vault.setAllowedTickRange(-600, 600);

        // Mint with ticks exactly at the boundaries
        vm.prank(agent);
        uint256 tokenId = vault.mintPosition(
            -600, // exactly at allowedTickLower
            600,  // exactly at allowedTickUpper
            1000e18,
            100e18,
            100e18,
            block.timestamp + 1 hours
        );

        assertTrue(vault.isManagedPosition(tokenId));
    }

    function test_IncreaseLiquidity_PositionExactlyAtBounds() public {
        // Mint position at bounds
        vm.prank(owner);
        vault.setAllowedTickRange(-600, 600);

        vm.prank(agent);
        uint256 tokenId = vault.mintPosition(
            -600, 600, 1000e18, 100e18, 100e18, block.timestamp + 1 hours
        );

        // Narrow bounds but position is still valid at exact edges
        vm.prank(owner);
        vault.setAllowedTickRange(-600, 600);

        // Increase should succeed as position is exactly at bounds
        vm.prank(agent);
        vault.increaseLiquidity(tokenId, 500e18, 50e18, 50e18, block.timestamp + 1 hours);
    }

    function test_IncreaseLiquidity_PositionLowerTickOutOfBounds() public {
        // Mint position
        vm.prank(agent);
        uint256 tokenId = vault.mintPosition(
            -1200, 600, 1000e18, 100e18, 100e18, block.timestamp + 1 hours
        );

        // Update bounds so only lower tick is out
        vm.prank(owner);
        vault.setAllowedTickRange(-600, 1200);

        // Should fail because lower tick is out of bounds
        vm.prank(agent);
        vm.expectRevert("position out of bounds");
        vault.increaseLiquidity(tokenId, 500e18, 50e18, 50e18, block.timestamp + 1 hours);
    }

    function test_IncreaseLiquidity_PositionUpperTickOutOfBounds() public {
        // Mint position
        vm.prank(agent);
        uint256 tokenId = vault.mintPosition(
            -600, 1200, 1000e18, 100e18, 100e18, block.timestamp + 1 hours
        );

        // Update bounds so only upper tick is out
        vm.prank(owner);
        vault.setAllowedTickRange(-1200, 600);

        // Should fail because upper tick is out of bounds
        vm.prank(agent);
        vm.expectRevert("position out of bounds");
        vault.increaseLiquidity(tokenId, 500e18, 50e18, 50e18, block.timestamp + 1 hours);
    }

    function test_BurnSinglePositionInArray() public {
        // Test burning when there's only one position
        uint256 tokenId = _mintTestPosition(-600, 600);

        assertEq(vault.positionsLength(), 1);

        vm.prank(agent);
        vault.burnPositionToVault(tokenId, 0, 0, block.timestamp + 1 hours);

        assertEq(vault.positionsLength(), 0);
    }

    function test_MintPosition_NegativeTickSpacing() public {
        // Note: This test documents behavior - negative tickSpacing would fail validation
        // The contract checks tickSpacing > 0, so negative would also fail
        // This is already covered by test_TickSpacingZero
    }

    function test_SwapExactInputSingle_ZeroSwapAmount() public {
        universalRouter.setSwapOutputAmount(0);

        // Swap with 0 minAmountOut should work
        vm.prank(agent);
        uint256 amountOut = vault.swapExactInputSingle(
            true,
            10e18,
            0, // minAmountOut = 0
            block.timestamp + 1 hours
        );

        assertEq(amountOut, 0);
    }

    // ============================================================
    // Fuzz Tests
    // ============================================================

    function testFuzz_SetAllowedTickRange(int24 tickLower, int24 tickUpper) public {
        // Bound to prevent overflow
        tickLower = int24(bound(tickLower, type(int24).min / 2, type(int24).max / 2 - 1));
        tickUpper = int24(bound(tickUpper, tickLower + 1, type(int24).max / 2));

        vm.prank(owner);
        vault.setAllowedTickRange(tickLower, tickUpper);

        assertEq(vault.allowedTickLower(), tickLower);
        assertEq(vault.allowedTickUpper(), tickUpper);
    }

    function testFuzz_SetMaxPositionsK(uint256 k) public {
        vm.prank(owner);
        vault.setMaxPositionsK(k);

        assertEq(vault.maxPositionsK(), k);
    }

    function testFuzz_Withdraw_ERC20(uint256 amount) public {
        amount = bound(amount, 0, 1000 ether);

        vm.prank(owner);
        vault.withdraw(Currency.wrap(address(token0)), amount, user);

        assertEq(token0.balanceOf(user), amount);
    }

    function testFuzz_Withdraw_ETH(uint256 amount) public {
        amount = bound(amount, 0, 100 ether);

        vm.prank(owner);
        vault.withdraw(Currency.wrap(address(0)), amount, user);

        assertEq(user.balance, amount);
    }

    // ============================================================
    // Integration / Scenario Tests
    // ============================================================

    function test_FullLifecycle_MintIncreasDecreaseCollectBurn() public {
        // 1. Mint a position
        uint256 tokenId = _mintTestPosition(-600, 600);
        assertEq(vault.positionsLength(), 1);

        // 2. Increase liquidity
        vm.prank(agent);
        vault.increaseLiquidity(tokenId, 500e18, 50e18, 50e18, block.timestamp + 1 hours);

        // 3. Decrease some liquidity
        vm.prank(agent);
        vault.decreaseLiquidityToVault(tokenId, 200e18, 0, 0, block.timestamp + 1 hours);

        // 4. Collect fees
        vm.prank(agent);
        vault.collectFeesToVault(tokenId, 0, 0, block.timestamp + 1 hours);

        // 5. Burn position
        vm.prank(agent);
        vault.burnPositionToVault(tokenId, 0, 0, block.timestamp + 1 hours);

        assertEq(vault.positionsLength(), 0);
        assertFalse(vault.isManagedPosition(tokenId));
    }

    function test_MultipleAgents_ChangeAgentMidOperation() public {
        address agent2 = makeAddr("agent2");

        // Agent 1 mints a position
        uint256 tokenId = _mintTestPosition(-600, 600);

        // Owner changes agent
        vm.prank(owner);
        vault.setAgent(agent2);

        // Old agent can no longer operate
        vm.prank(agent);
        vm.expectRevert("not agent");
        vault.increaseLiquidity(tokenId, 500e18, 50e18, 50e18, block.timestamp + 1 hours);

        // New agent can operate
        vm.prank(agent2);
        vault.increaseLiquidity(tokenId, 500e18, 50e18, 50e18, block.timestamp + 1 hours);
    }

    function test_OwnerEmergencyWorkflow() public {
        // Simulate an emergency scenario

        // 1. Agent creates multiple positions
        _mintTestPosition(-600, 600);
        _mintTestPosition(-1200, 1200);
        _mintTestPosition(-1800, 1800);
        assertEq(vault.positionsLength(), 3);

        // 2. Owner detects issue and pauses + exits all
        vm.prank(owner);
        vault.pauseAndExitAll(block.timestamp + 1 hours);

        // 3. All positions burned, agent paused
        assertEq(vault.positionsLength(), 0);
        assertTrue(vault.agentPaused());

        // 4. Agent cannot operate
        vm.prank(agent);
        vm.expectRevert("agent paused");
        vault.mintPosition(-600, 600, 1000e18, 100e18, 100e18, block.timestamp + 1 hours);

        // 5. Owner can withdraw all funds
        uint256 token0Balance = token0.balanceOf(address(vault));
        vm.prank(owner);
        vault.withdraw(Currency.wrap(address(token0)), token0Balance, owner);
        assertEq(token0.balanceOf(address(vault)), 0);
    }

    function test_TickRangeUpdateDuringActivePositions() public {
        // Create positions at different ranges
        uint256 pos1 = _mintTestPosition(-600, 600);    // narrow
        uint256 pos2 = _mintTestPosition(-6000, 6000);  // wide

        // Update allowed range to exclude pos2
        vm.prank(owner);
        vault.setAllowedTickRange(-1000, 1000);

        // pos1 can still be increased (within bounds)
        vm.prank(agent);
        vault.increaseLiquidity(pos1, 500e18, 50e18, 50e18, block.timestamp + 1 hours);

        // pos2 cannot be increased (out of bounds)
        vm.prank(agent);
        vm.expectRevert("position out of bounds");
        vault.increaseLiquidity(pos2, 500e18, 50e18, 50e18, block.timestamp + 1 hours);

        // But pos2 can still be burned
        vm.prank(agent);
        vault.burnPositionToVault(pos2, 0, 0, block.timestamp + 1 hours);

        assertEq(vault.positionsLength(), 1);
    }

    function test_SwapAndMintSequence() public {
        // Test combining swap and mint operations
        universalRouter.setSwapOutputAmount(95e18);

        // Swap some tokens
        vm.prank(agent);
        uint256 swapOut = vault.swapExactInputSingle(
            true,
            100e18,
            90e18,
            block.timestamp + 1 hours
        );
        assertGe(swapOut, 90e18);

        // Then mint a position
        uint256 tokenId = _mintTestPosition(-600, 600);
        assertTrue(vault.isManagedPosition(tokenId));
    }

    // ============================================================
    // Coverage Note
    // ============================================================
    // The only uncovered branch (line 465 in _removeManagedPosition) is a
    // defensive require that checks isManagedPosition[tokenId]. This check
    // is unreachable from normal contract flow because:
    // 1. burnPositionToVault checks isManagedPosition before calling _removeManagedPosition
    // 2. pauseAndExitAll only iterates over positionIds which are always managed
    // This is intentional defensive programming and does not indicate missing test coverage.

    // ============================================================
    // Helper Functions
    // ============================================================

    function _mintTestPosition(int24 tickLower, int24 tickUpper) internal returns (uint256 tokenId) {
        vm.prank(agent);
        tokenId = vault.mintPosition(
            tickLower,
            tickUpper,
            1000e18,
            100e18,
            100e18,
            block.timestamp + 1 hours
        );
    }
}

// Helper contract that rejects ETH
contract RejectETH {
    receive() external payable {
        revert("no ETH");
    }
}
