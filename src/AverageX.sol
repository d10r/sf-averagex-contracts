pragma solidity 0.8.19;

import { ISuperfluid, ISuperToken, IConstantFlowAgreementV1, IGeneralDistributionAgreementV1, ISuperfluidPool } from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";
import { PoolConfig } from "@superfluid-finance/ethereum-contracts/contracts/interfaces/agreements/gdav1/IGeneralDistributionAgreementV1.sol";
import { SuperAppBaseFlow } from "@superfluid-finance/ethereum-contracts/contracts/apps/SuperAppBaseFlow.sol";
import { SuperTokenV1Library } from "@superfluid-finance/ethereum-contracts/contracts/apps/SuperTokenV1Library.sol";

using SuperTokenV1Library for ISuperToken;

// Helpers

function toU128(int96 i96) pure returns (uint128) {
    return uint128(uint96(i96));
}

/// Interface to be implemented by Liquidity Mover contracts
interface ILiquidityMover {
    function execute() external;
}

/// implements the Torex core mechanism: get flows in inToken, allow liquidity moving to outToken with price constraints applied
/// A Torex instance is tied to pair of tokens, defined at creation time.
/// Only one-way swaps from inToken -> outToken are supported. For reverse swaps, a distinct Torex instance is needed.
contract Torex is SuperAppBaseFlow {
    // ERRORS
    error NOT_ACCEPTED_SUPERTOKEN();

    // STATE
    // CONFIG
    ISuperfluid public host;
    ISuperToken public immutable inToken;
    ISuperToken public immutable outToken;

    // INIT
    constructor(ISuperfluid host_, ISuperToken inToken_, ISuperToken outToken_) 
        SuperAppBaseFlow(host_, true, true, true, "")
    {
        host = host_;
        inToken = inToken_;
        outToken = outToken_;
    }

    // --- handle inflows

    // SuperAppBaseFlow hook
    function onFlowCreated(ISuperToken superToken, address sender, bytes calldata ctx)
        internal override returns (bytes memory newCtx)
    {
        if (superToken != inToken) revert NOT_ACCEPTED_SUPERTOKEN();
        int96 inFlowRate = superToken.getFlowRate(sender, address(this));
        bytes memory userData = host.decodeCtx(ctx).userData;
        newCtx = onInFlowChanged(sender, 0, inFlowRate, userData, ctx);
    }

    /// this method shall be overridden for added functionality
    /// precondition: superToken == inToken
    function onInFlowChanged(address sender, int96 prevFlowRate, int96 flowRate, bytes memory userData, bytes memory ctx)
        internal virtual returns (bytes memory newCtx)
    {
        newCtx = ctx;
    }

    // --- move liquidity

    /// returns the price of assetB denominated in inToken at which a swap is now allowed.
    /// price is dictated by the associated TWAP oracle, with some offset applier
    /// the offset may change over time in order to increase the incentive to execute.
    function getSwapPrice() public returns(uint256 price) {
        // TODO: calculate based on UniV3 TWAP
    }

    /// Allows an LM to execute a swap of inToken to outToken.
    /// The amounts need to be satisfy the price threshold defined by getSwapPrice().
    /// Sends inAmount inToken to msg.sender and expects to get outAmount outToken in return, otherwise reverts.
    function moveLiquidity(uint256 inAmount, uint256 outAmount) public {
        require(outAmount * getSwapPrice() >= inAmount);
        inToken.transfer(msg.sender, inAmount);
        // TODO; what params does it need? none may work if the implementer is expected to keep track of args provided to swap()
        (ILiquidityMover(msg.sender)).execute();
        outToken.transferFrom(msg.sender, address(this), outAmount);
        // TODO: distribute, check reentrancy, emit event
    }
}

/// implements the incentive system
/// * keeps track of staked AVG. Changes in stake update feeDistributionPool
/// * keeps track of inflows. Changes in inflows update rewardsDistributionPool
contract TorexWithIncentives is Torex {
    // CONFIG
    /// fee in inToken, as proportion of inflows - Per Million
    uint32 feePM;
    // TODO: add fee share for the protocol (merged into pool or dedicated flow)
    ISuperToken rewardToken;

    // STATE
    // GDA pool for distributing inToken fees to stakers
    ISuperfluidPool public feeDistributionPool;
    // GDA pool for distributing rewardToken rewards to inToken flow senders
    ISuperfluidPool public rewardDistributionPool;
    int96 public cumulatedInFlowRate; // TODO: what's the correct type here?

    // INIT
    constructor(ISuperfluid host_, ISuperToken inToken_, ISuperToken outToken_, uint32 feePM_, ISuperToken rewardToken_)
        Torex(host_, inToken_, outToken_)
    {
        feePM = feePM_;
        rewardToken = rewardToken_;
        // no unit transferrability, open to all
        PoolConfig memory poolConfig = PoolConfig(false, true);
        feeDistributionPool = inToken.createPool(address(this), poolConfig);
        rewardDistributionPool = rewardToken.createPool(address(this), poolConfig);
    }

    // --- hooks for changes in inflows
    function onInFlowChanged(address sender, int96 prevFlowRate, int96 flowRate, bytes memory userData, bytes memory ctx)
        internal override returns (bytes memory newCtx)
    {
        newCtx = ctx;

        // adjust cumulated inFlowRate (book keeping)
        int96 deltaFlowRate = flowRate - prevFlowRate;
        // this can't get negative until there's a logic error
        cumulatedInFlowRate += deltaFlowRate;

        // update units of sender in the reward distribution pool
        rewardDistributionPool.updateMemberUnits(sender, toU128(flowRate)); // TODO: is it safe to map flowrate to units 1:1? probably yes.

        // update flowrate to the fee distribution pool, accounting for the changed inFlow
        int96 feeFlowRate = cumulatedInFlowRate * int32(feePM) / 1e6; // TODO: is this the correct casting
        inToken.distributeFlow(address(this), feeDistributionPool, feeFlowRate);

        // TODO: special cases:
        // * first inFlow created: create flow to pool
        // * last inFlow deleted: delete flow to pool

        return super.onInFlowChanged(sender, prevFlowRate, flowRate, userData, newCtx);
    }

    // --- stake/unstake rewardTokens

    // Fetches amount rewardTokens from msg.sender using ERC20.transferFrom()
    // and updates the sender's units in the the feeDistributionPool accordingly.
    // TODO: add variant to be invoked as send() receive callback ?
    function stake(uint256 amount) public {
        rewardToken.transferFrom(msg.sender, address(this), amount);
        // TODO: is it safe to map amount to units 1:1? probably yes if we put some explicit constraints on allowed rewardToken supply.
        rewardDistributionPool.updateMemberUnits(msg.sender, uint128(amount));
        // TODO: emit event
    }

    // Returns amount rewardTokens to msg.sender using ERC20.transfer()
    // and updates the sender's units in the the feeDistributionPool accordingly.
    function unstake(uint256 amount) public {
        uint128 poolUnits = feeDistributionPool.getUnits(msg.sender);
        require(poolUnits >= amount); // TODO: emit custom error
        feeDistributionPool.updateMemberUnits(msg.sender, poolUnits - uint128(amount));
        rewardToken.transfer(msg.sender, amount);
        // TODO: emit event
    }
}

/// Main contract of the system
/// * Torex Factory
/// * Distributes AVG tokens to Torexes
contract AverageX {
    // create torex
}