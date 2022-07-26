// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

import {ISuperfluid, ISuperToken, ISuperfluidToken, ISuperApp, ISuperAgreement, SuperAppDefinitions} from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";
import {SuperAppBase} from "@superfluid-finance/ethereum-contracts/contracts/apps/SuperAppBase.sol";
import {CFAv1Library} from "@superfluid-finance/ethereum-contracts/contracts/apps/CFAv1Library.sol";
import {IConstantFlowAgreementV1} from "@superfluid-finance/ethereum-contracts/contracts/interfaces/agreements/IConstantFlowAgreementV1.sol";

import "./libraries/UQ128x128.sol";
import "./libraries/math.sol";
import "./interfaces/IAqueductHost.sol";
import "./interfaces/IAqueductToken.sol";

contract SuperApp is SuperAppBase, IAqueductHost {
    using UQ128x128 for uint256;

    /* --- Superfluid --- */
    using CFAv1Library for CFAv1Library.InitData;
    CFAv1Library.InitData public cfaV1;
    bytes32 public constant CFA_ID =
        keccak256("org.superfluid-finance.agreements.ConstantFlowAgreement.v1");
    IConstantFlowAgreementV1 cfa;
    ISuperfluid _host;

    /* --- Pool variables --- */
    address public factory;
    uint256 poolFee;
    IAqueductToken public token0;
    IAqueductToken public token1;

    // pool flows
    uint128 private flowIn0;
    uint128 private flowIn1;

    // price accumulators
    uint256 public price0CumulativeLast;
    uint256 public price1CumulativeLast;

    // fees flows
    int96 private feesFlow0;
    int96 private feesFlow1;

    // liquidity flows and accumulators
    int96 private liquidityFlow0;
    int96 private liquidityFlow1;
    uint256 fees0CumulativeLast;
    uint256 fees1CumulativeLast;

    // timestamp of last pool update
    uint32 private blockTimestampLast;

    // map user address to their starting price cumulatives
    struct UserData {
        int96 flowIn0;
        int96 flowIn1;
        int96 flowOut0;
        int96 flowOut1;
        uint256 price0Cumulative;
        uint256 price1Cumulative;
        int96 liquidityFlow0;
        int96 liquidityFlow1;
        uint256 fees0Cumulative;
        uint256 fees1Cumulative;
    }
    mapping(address => UserData) private userData;

    constructor(ISuperfluid host) payable {
        assert(address(host) != address(0));

        _host = host;
        factory = msg.sender;

        cfa = IConstantFlowAgreementV1(address(host.getAgreementClass(CFA_ID)));
        cfaV1 = CFAv1Library.InitData(host, cfa);

        uint256 configWord = SuperAppDefinitions.APP_LEVEL_FINAL |
            SuperAppDefinitions.BEFORE_AGREEMENT_CREATED_NOOP;

        host.registerApp(configWord);
    }

    // called once by the factory at time of deployment
    function initialize(
        IAqueductToken _token0,
        IAqueductToken _token1,
        uint224 _poolFee
    ) external {
        require(msg.sender == factory, "FORBIDDEN"); // sufficient check
        token0 = _token0;
        token1 = _token1;
        poolFee = _poolFee;
    }

    /* --- Helper functions --- */

    function getFlowIn(ISuperToken token) external view returns (uint128 flowIn) {
        if (token == token0) {
            flowIn = flowIn0;
        } else {
            flowIn = flowIn1;
        }
    }

    function getUserFromCtx(bytes calldata _ctx)
        internal
        view
        returns (address user)
    {
        return _host.decodeCtx(_ctx).msgSender;
    }

    /* Gets the incoming flowRate for a given supertoken/user */
    function getFlowRateIn(ISuperToken token, address user)
        internal
        view
        returns (int96)
    {
        (, int96 flowRate, , ) = cfa.getFlow(token, user, address(this));

        return flowRate;
    }

    /* Gets the outgoing flowRate for a given supertoken/user */
    function getFlowRateOut(ISuperToken token, address user)
        internal
        view
        returns (int96)
    {
        (, int96 flowRate, , ) = cfa.getFlow(token, address(this), user);

        return flowRate;
    }

    /* Gets the fee percentage for a given supertoken/user */
    function getFeePercentage(
        int96 flowA,
        int96 flowB,
        uint128 poolFlowA,
        uint128 poolFlowB
    ) internal pure returns (uint256) {
        // handle special case
        if (flowB == 0 || poolFlowB == 0) {
            return UQ128x128.Q128;
        }

        // TODO: check that int96 -> uint128 cast is safe - expected that a flow between sender and receiver will always be positive
        uint256 userRatio = UQ128x128.encode(uint128(uint96(flowA))).uqdiv(
            uint128(uint96(flowB))
        );
        uint256 poolRatio = UQ128x128.encode(poolFlowA).uqdiv(poolFlowB);

        if ((userRatio + poolRatio) == 0) {
            return UQ128x128.Q128;
        } else {
            return
                math.difference(userRatio, poolRatio) / (userRatio + poolRatio);
        }
    }

    /* --- Pool functions --- */

    function getCumulativesAtTime(uint256 timestamp)
        internal
        view
        returns (uint256 pc0, uint256 pc1)
    {
        uint32 timestamp32 = uint32(timestamp % 2**32);
        uint32 timeElapsed = timestamp32 - blockTimestampLast;
        uint128 _flowIn0 = flowIn0;
        uint128 _flowIn1 = flowIn1;

        pc0 = price0CumulativeLast;
        pc1 = price1CumulativeLast;
        if (_flowIn0 > 0 && _flowIn1 > 0) {
            pc1 += (uint256(UQ128x128.encode(_flowIn1).uqdiv(_flowIn0)) *
                timeElapsed);
            pc0 += (uint256(UQ128x128.encode(_flowIn0).uqdiv(_flowIn1)) *
                timeElapsed);
        }
    }

    function getRealTimeCumulatives()
        external
        view
        returns (uint256 pc0, uint256 pc1)
    {
        (pc0, pc1) = getCumulativesAtTime(block.timestamp);
    }

    function getFeesCumulativeAtTime(address token, uint256 timestamp)
        internal
        view
        returns (uint256 feesCumulative)
    {
        if (token == address(token0)) {
            if (liquidityFlow0 > 0 && flowIn0 > 0 && flowIn1 > 0) {
                feesCumulative =
                    fees0CumulativeLast +
                    UQ128x128.halfDecode(
                        UQ128x128.encode(uint128(int128(feesFlow0))).uqdiv(
                            uint128(int128(liquidityFlow0))
                        ) *
                            UQ128x128.halfDecode(
                                UQ128x128.encode(flowIn0).uqdiv(flowIn1) *
                                    (timestamp - blockTimestampLast)
                            )
                    );
            }
        } else {
            if (liquidityFlow1 > 0 && flowIn0 > 0 && flowIn1 > 0) {
                feesCumulative =
                    fees1CumulativeLast +
                    UQ128x128.halfDecode(
                        UQ128x128.encode(uint128(int128(feesFlow1))).uqdiv(
                            uint128(int128(liquidityFlow1))
                        ) *
                            UQ128x128.halfDecode(
                                UQ128x128.encode(flowIn1).uqdiv(flowIn0) *
                                    (timestamp - blockTimestampLast)
                            )
                    );
            }
        }
    }

    function getRealTimeFeesCumulative(address token)
        public
        view
        returns (uint256 feesCumulative)
    {
        feesCumulative = getFeesCumulativeAtTime(token, block.timestamp);
    }

    function getUserCumulativeDelta(
        address token,
        address user,
        uint256 timestamp
    ) public view returns (uint256 cumulativeDelta) {
        if (token == address(token0)) {
            (uint256 S, ) = getCumulativesAtTime(timestamp);
            uint256 S0 = userData[user].price0Cumulative;
            cumulativeDelta = S - S0;
        } else if (token == address(token1)) {
            (, uint256 S) = getCumulativesAtTime(timestamp);
            uint256 S0 = userData[user].price1Cumulative;
            cumulativeDelta = S - S0;
        }
    }

    function getRealTimeUserCumulativeDelta(address token, address user)
        external
        view
        returns (uint256 cumulativeDelta)
    {
        cumulativeDelta = getUserCumulativeDelta(token, user, block.timestamp);
    }

    function getUserReward(
        address token,
        address user,
        uint256 timestamp
    ) public view returns (int256 reward) {
        int256 liquidityFlow;
        if (token == address(token0)) {
            liquidityFlow = int256(
                user == address(this)
                    ? liquidityFlow0 * -1
                    : userData[user].liquidityFlow0
            );
        } else {
            liquidityFlow = int256(
                user == address(this)
                    ? liquidityFlow1 * -1
                    : userData[user].liquidityFlow1
            );
        }

        uint256 initialFeesCumulative = token == address(token0)
            ? userData[user].fees0Cumulative
            : userData[user].fees1Cumulative;

        uint256 currentFeesCumulative = getFeesCumulativeAtTime(
            token,
            timestamp
        );

        reward =
            (liquidityFlow *
                int256(currentFeesCumulative - initialFeesCumulative)) /
            2**128;
    }

    function getRealTimeUserReward(address token, address user)
        external
        view
        returns (int256 reward)
    {
        reward = getUserReward(token, user, block.timestamp);
    }

    function getTwapNetFlowRate(address token, address user)
        external
        view
        returns (int96 netFlowRate)
    {
        if (token == address(token0)) {
            netFlowRate = userData[user].flowOut0;
        } else {
            netFlowRate = userData[user].flowOut1;
        }
    }

    function _updateFeesAndRewards(
        int96 relFeesFlow0,
        int96 relFeesFlow1,
        int96 userLiquidityFlow0,
        int96 userLiquidityFlow1,
        address user
    ) private {
        // update fees accumulators
        fees0CumulativeLast = getRealTimeFeesCumulative(address(token0));
        fees1CumulativeLast = getRealTimeFeesCumulative(address(token1));
        userData[user].fees0Cumulative = fees0CumulativeLast;
        userData[user].fees1Cumulative = fees1CumulativeLast;
        userData[address(this)].fees0Cumulative = fees0CumulativeLast;
        userData[address(this)].fees1Cumulative = fees1CumulativeLast;

        // update fees flows
        feesFlow0 -= userData[user].flowIn1 - userData[user].flowOut0;
        feesFlow1 -= userData[user].flowIn0 - userData[user].flowOut1;
        feesFlow0 += relFeesFlow0; //flow.userFlowIn1 - flow.userFlowOut0;
        feesFlow1 += relFeesFlow1; //flow.userFlowIn0 - flow.userFlowOut1;

        // update liquidity flows
        liquidityFlow0 -= userData[user].liquidityFlow0;
        liquidityFlow1 -= userData[user].liquidityFlow1;
        liquidityFlow0 += userLiquidityFlow0;
        liquidityFlow1 += userLiquidityFlow1;
        userData[user].liquidityFlow0 = userLiquidityFlow0;
        userData[user].liquidityFlow1 = userLiquidityFlow1;
    }

    // update flow reserves and, on the first call per block, price accumulators
    function _update(
        uint128 _flowIn0,
        uint128 _flowIn1,
        int96 relFlowIn0,
        int96 relFlowIn1,
        int96 relFlowOut0,
        int96 relFlowOut1,
        address user
    ) private {
        uint32 blockTimestamp = uint32(block.timestamp % 2**32);
        uint32 timeElapsed = blockTimestamp - blockTimestampLast;

        if (_flowIn0 != 0 && _flowIn1 != 0) {
            if (timeElapsed <= 0) {
                timeElapsed = 0;
            }

            price1CumulativeLast +=
                uint256(UQ128x128.encode(_flowIn1).uqdiv(_flowIn0)) *
                timeElapsed;
            price0CumulativeLast +=
                uint256(UQ128x128.encode(_flowIn0).uqdiv(_flowIn1)) *
                timeElapsed;

            // update user and pool initial price cumulatives
            if (relFlowOut0 != 0) {
                userData[user].price0Cumulative = price0CumulativeLast;
                userData[address(this)].price0Cumulative = price0CumulativeLast;
                userData[address(this)].price1Cumulative = price1CumulativeLast;
            }
            if (relFlowOut1 != 0) {
                userData[user].price1Cumulative = price1CumulativeLast;
                userData[address(this)].price0Cumulative = price0CumulativeLast;
                userData[address(this)].price1Cumulative = price1CumulativeLast;
            }
        }

        if (relFlowIn0 != 0) {
            userData[user].flowIn0 += relFlowIn0;
        }
        if (relFlowIn1 != 0) {
            userData[user].flowIn1 += relFlowIn1;
        }
        if (relFlowOut0 != 0) {
            userData[user].flowOut0 += relFlowOut0;
            userData[address(this)].flowOut0 -= relFlowOut0;
        }
        if (relFlowOut1 != 0) {
            userData[user].flowOut1 += relFlowOut1;
            userData[address(this)].flowOut1 -= relFlowOut1;
        }

        flowIn0 = math.safeUnsignedAdd(_flowIn0, relFlowIn0);
        flowIn1 = math.safeUnsignedAdd(_flowIn1, relFlowIn1);

        blockTimestampLast = blockTimestamp;
    }

    struct UpdatedFees {
        uint256 feePercentage0;
        uint256 feePercentage1;
        uint256 feeMultiplier0;
        uint256 feeMultiplier1;
    }

    // fees are dependent upon flowRates of both tokens, update both at once
    function getUserOutflows(
        uint128 _flowIn0,
        uint128 _flowIn1,
        int96 previousUserFlowIn0,
        int96 previousUserFlowIn1,
        int96 userFlowIn0,
        int96 userFlowIn1
    )
        private
        view
        returns (
            int96 userFlowOut0,
            int96 userFlowOut1,
            int96 userLiquidityFlow0,
            int96 userLiquidityFlow1
        )
    {
        // calculate expected pool reserves
        _flowIn0 = math.safeUnsignedAdd(
            _flowIn0,
            userFlowIn0 - previousUserFlowIn0
        );
        _flowIn1 = math.safeUnsignedAdd(
            _flowIn1,
            userFlowIn1 - previousUserFlowIn1
        );

        // calculate fee percentages
        UpdatedFees memory updatedFees;
        updatedFees.feePercentage0 = getFeePercentage(
            userFlowIn0,
            userFlowIn1,
            _flowIn0,
            _flowIn1
        );
        updatedFees.feeMultiplier0 =
            UQ128x128.Q128 -
            ((updatedFees.feePercentage0 * poolFee) / UQ128x128.Q128);

        updatedFees.feePercentage1 = getFeePercentage(
            userFlowIn1,
            userFlowIn0,
            _flowIn1,
            _flowIn0
        );
        updatedFees.feeMultiplier1 =
            UQ128x128.Q128 -
            ((updatedFees.feePercentage1 * poolFee) / UQ128x128.Q128);

        // calculate outflows
        // TODO: check for overflow
        userFlowOut0 = int96(
            int256(
                UQ128x128.decode(
                    updatedFees.feeMultiplier1 * uint256(uint96(userFlowIn1))
                )
            )
        );
        userFlowOut1 = int96(
            int256(
                UQ128x128.decode(
                    updatedFees.feeMultiplier0 * uint256(uint96(userFlowIn0))
                )
            )
        );

        // calculate liquidity flows
        userLiquidityFlow0 = int96(
            int256(
                UQ128x128.decode(
                    (UQ128x128.Q128 - updatedFees.feePercentage0) *
                        uint256(uint96(userFlowIn0))
                )
            )
        );
        userLiquidityFlow1 = int96(
            int256(
                UQ128x128.decode(
                    (UQ128x128.Q128 - updatedFees.feePercentage1) *
                        uint256(uint96(userFlowIn1))
                )
            )
        );
    }

    /* --- Superfluid callbacks --- */

    struct Flow {
        address user;
        bool isToken0;
        int96 userFlowIn0;
        int96 userFlowIn1;
        int96 userFlowOut0;
        int96 userFlowOut1;
        int96 userLiquidityFlow0;
        int96 userLiquidityFlow1;
        int96 previousUserFlowOut0;
        int96 previousUserFlowOut1;
        int96 previousUserFlowIn;
        uint256 initialTimestamp0;
        uint256 initialTimestamp1;
        bool forceSettleUserBalances;
    }

    //onlyExpected(_agreementClass)
    function afterAgreementCreated(
        ISuperToken _superToken,
        address, //_agreementClass,
        bytes32, //_agreementId
        bytes calldata, //_agreementData
        bytes calldata, //_cbdata,
        bytes calldata _ctx
    ) external override onlyHost returns (bytes memory newCtx) {
        require(
            address(_superToken) == address(token0) ||
                address(_superToken) == address(token1),
            "RedirectAll: token not in pool"
        );

        // avoid stack too deep
        Flow memory flow;
        flow.user = getUserFromCtx(_ctx);
        flow.isToken0 = address(_superToken) == address(token0);
        flow.userFlowIn0 = getFlowRateIn(token0, flow.user);
        flow.userFlowIn1 = getFlowRateIn(token1, flow.user);
        flow.previousUserFlowOut0 = getFlowRateOut(token0, flow.user);
        flow.previousUserFlowOut1 = getFlowRateOut(token1, flow.user);

        /*
        require(
            (flow.isToken0 && )
        );
        */

        (
            flow.userFlowOut0,
            flow.userFlowOut1,
            flow.userLiquidityFlow0,
            flow.userLiquidityFlow1
        ) = getUserOutflows(
            flowIn0,
            flowIn1,
            flow.isToken0 ? int96(0) : flow.userFlowIn0,
            flow.isToken0 ? flow.userFlowIn1 : int96(0),
            flow.userFlowIn0,
            flow.userFlowIn1
        );

        newCtx = cfaV1.createFlowWithCtx(
            _ctx,
            flow.user,
            flow.isToken0 ? token1 : token0,
            flow.isToken0 ? flow.userFlowOut1 : flow.userFlowOut0
        );
        if (
            (flow.isToken0 && flow.previousUserFlowOut0 != flow.userFlowOut0) ||
            (!flow.isToken0 && flow.previousUserFlowOut1 != flow.userFlowOut1)
        ) {
            newCtx = cfaV1.updateFlowWithCtx(
                newCtx,
                flow.user,
                _superToken,
                flow.isToken0 ? flow.userFlowOut0 : flow.userFlowOut1
            );
        }

        // update variables for tracking fees and rewards
        _updateFeesAndRewards(
            flow.userFlowIn1 - flow.userFlowOut0,
            flow.userFlowIn0 - flow.userFlowOut1,
            flow.userLiquidityFlow0,
            flow.userLiquidityFlow1,
            flow.user
        );

        // rebalance
        _update(
            flowIn0,
            flowIn1,
            flow.isToken0 ? flow.userFlowIn0 : int96(0),
            flow.isToken0 ? int96(0) : flow.userFlowIn1,
            flow.userFlowOut0 - flow.previousUserFlowOut0,
            flow.userFlowOut1 - flow.previousUserFlowOut1,
            flow.user
        );
    }

    function beforeAgreementUpdated(
        ISuperToken _superToken,
        address, // agreementClass
        bytes32, // agreementId
        bytes calldata, // agreementData
        bytes calldata _ctx
    )
        external
        view
        virtual
        override
        returns (
            bytes memory // cbdata
        )
    {
        // keep track of old flowRate to calc net change in afterAgreementTerminated
        address user = getUserFromCtx(_ctx);
        int96 flowRate = getFlowRateIn(_superToken, user);

        // get previous initial flow timestamps (in case balance needs to be manually settled)
        (uint256 initialTimestamp0, , , ) = cfa.getAccountFlowInfo(
            token0,
            user
        );
        (uint256 initialTimestamp1, , , ) = cfa.getAccountFlowInfo(
            token1,
            user
        );

        return abi.encode(flowRate, initialTimestamp0, initialTimestamp1);
    }

    // onlyExpected(_agreementClass)
    function afterAgreementUpdated(
        ISuperToken _superToken,
        address, //_agreementClass,
        bytes32, // _agreementId,
        bytes calldata, // _agreementData,
        bytes calldata _cbdata,
        bytes calldata _ctx
    ) external override onlyHost returns (bytes memory newCtx) {
        require(
            address(_superToken) == address(token0) ||
                address(_superToken) == address(token1),
            "RedirectAll: token not in pool"
        );

        // avoid stack too deep
        Flow memory flow;
        flow.user = getUserFromCtx(_ctx);
        flow.isToken0 = address(_superToken) == address(token0);
        flow.userFlowIn0 = getFlowRateIn(token0, flow.user);
        flow.userFlowIn1 = getFlowRateIn(token1, flow.user);
        flow.previousUserFlowOut0 = getFlowRateOut(token0, flow.user);
        flow.previousUserFlowOut1 = getFlowRateOut(token1, flow.user);

        (
            flow.previousUserFlowIn,
            flow.initialTimestamp0,
            flow.initialTimestamp1
        ) = abi.decode(_cbdata, (int96, uint256, uint256));

        // settle balances if necessary
        flow.forceSettleUserBalances =
            userData[flow.user].flowOut0 == userData[flow.user].flowOut1;
        if (flow.forceSettleUserBalances) {
            token0.settleTwapBalance(flow.user, flow.initialTimestamp0);
            token1.settleTwapBalance(flow.user, flow.initialTimestamp1);
        }

        (
            flow.userFlowOut0,
            flow.userFlowOut1,
            flow.userLiquidityFlow0,
            flow.userLiquidityFlow1
        ) = getUserOutflows(
            flowIn0,
            flowIn1,
            flow.isToken0 ? flow.previousUserFlowIn : flow.userFlowIn0,
            flow.isToken0 ? flow.userFlowIn1 : flow.previousUserFlowIn,
            flow.userFlowIn0,
            flow.userFlowIn1
        );

        newCtx = cfaV1.updateFlowWithCtx(
            _ctx,
            flow.user,
            flow.isToken0 ? token1 : token0,
            flow.isToken0 ? flow.userFlowOut1 : flow.userFlowOut0
        );
        if (
            (flow.isToken0 && flow.previousUserFlowOut0 != flow.userFlowOut0) ||
            (!flow.isToken0 && flow.previousUserFlowOut1 != flow.userFlowOut1)
        ) {
            newCtx = cfaV1.updateFlowWithCtx(
                newCtx,
                flow.user,
                _superToken,
                flow.isToken0 ? flow.userFlowOut0 : flow.userFlowOut1
            );
        }

        // update variables for tracking fees and rewards
        _updateFeesAndRewards(
            flow.userFlowIn1 - flow.userFlowOut0,
            flow.userFlowIn0 - flow.userFlowOut1,
            flow.userLiquidityFlow0,
            flow.userLiquidityFlow1,
            flow.user
        );

        // rebalance
        _update(
            flowIn0,
            flowIn1,
            flow.isToken0
                ? flow.userFlowIn0 - flow.previousUserFlowIn
                : int96(0),
            flow.isToken0
                ? int96(0)
                : flow.userFlowIn1 - flow.previousUserFlowIn,
            flow.userFlowOut0 - flow.previousUserFlowOut0,
            flow.userFlowOut1 - flow.previousUserFlowOut1,
            flow.user
        );

        // update cumualtives if necessary
        if (flow.forceSettleUserBalances) {
            userData[flow.user].price0Cumulative = price0CumulativeLast;
            userData[flow.user].price1Cumulative = price1CumulativeLast;
        }
    }

    function beforeAgreementTerminated(
        ISuperToken _superToken,
        address, // agreementClass
        bytes32, // agreementId
        bytes calldata, // agreementData
        bytes calldata _ctx
    )
        external
        view
        virtual
        override
        returns (
            bytes memory // cbdata
        )
    {
        // keep track of old flowRate to calc net change in afterAgreementTerminated
        address user = getUserFromCtx(_ctx);
        int96 flowRate = getFlowRateIn(_superToken, user);

        // get previous initial flow timestamps (in case balance needs to be manually settled)
        (uint256 initialTimestamp0, , , ) = cfa.getAccountFlowInfo(
            token0,
            user
        );
        (uint256 initialTimestamp1, , , ) = cfa.getAccountFlowInfo(
            token1,
            user
        );

        return abi.encode(flowRate, initialTimestamp0, initialTimestamp1);
    }

    function afterAgreementTerminated(
        ISuperToken _superToken,
        address, //_agreementClass,
        bytes32, // _agreementId,
        bytes calldata, // _agreementData
        bytes calldata _cbdata,
        bytes calldata _ctx
    ) external override onlyHost returns (bytes memory newCtx) {
        require(
            address(_superToken) == address(token0) ||
                address(_superToken) == address(token1),
            "RedirectAll: token not in pool"
        );

        // avoid stack too deep
        Flow memory flow;
        flow.user = getUserFromCtx(_ctx);
        flow.isToken0 = address(_superToken) == address(token0);
        flow.userFlowIn0 = getFlowRateIn(token0, flow.user);
        flow.userFlowIn1 = getFlowRateIn(token1, flow.user);
        flow.previousUserFlowOut0 = getFlowRateOut(token0, flow.user);
        flow.previousUserFlowOut1 = getFlowRateOut(token1, flow.user);

        (
            flow.previousUserFlowIn,
            flow.initialTimestamp0,
            flow.initialTimestamp1
        ) = abi.decode(_cbdata, (int96, uint256, uint256));

        // settle balances if necessary
        flow.forceSettleUserBalances =
            userData[flow.user].flowOut0 == userData[flow.user].flowOut1;
        if (flow.forceSettleUserBalances) {
            token0.settleTwapBalance(flow.user, flow.initialTimestamp0);
            token1.settleTwapBalance(flow.user, flow.initialTimestamp1);
        }

        (
            flow.userFlowOut0,
            flow.userFlowOut1,
            flow.userLiquidityFlow0,
            flow.userLiquidityFlow1
        ) = getUserOutflows(
            flowIn0,
            flowIn1,
            flow.isToken0 ? flow.previousUserFlowIn : flow.userFlowIn0,
            flow.isToken0 ? flow.userFlowIn1 : flow.previousUserFlowIn,
            flow.userFlowIn0,
            flow.userFlowIn1
        );

        newCtx = cfaV1.deleteFlowWithCtx(
            _ctx,
            address(this),
            flow.user,
            flow.isToken0 ? token1 : token0
        );
        if (
            (flow.isToken0 && flow.previousUserFlowOut0 != flow.userFlowOut0) ||
            (!flow.isToken0 && flow.previousUserFlowOut1 != flow.userFlowOut1)
        ) {
            newCtx = cfaV1.updateFlowWithCtx(
                newCtx,
                flow.user,
                _superToken,
                flow.isToken0 ? flow.userFlowOut0 : flow.userFlowOut1
            );
        }

        // update variables for tracking fees and rewards
        _updateFeesAndRewards(
            flow.userFlowIn1 - flow.userFlowOut0,
            flow.userFlowIn0 - flow.userFlowOut1,
            flow.userLiquidityFlow0,
            flow.userLiquidityFlow1,
            flow.user
        );

        // rebalance
        _update(
            flowIn0,
            flowIn1,
            flow.isToken0
                ? flow.userFlowIn0 - flow.previousUserFlowIn
                : int96(0),
            flow.isToken0
                ? int96(0)
                : flow.userFlowIn1 - flow.previousUserFlowIn,
            flow.userFlowOut0 - flow.previousUserFlowOut0,
            flow.userFlowOut1 - flow.previousUserFlowOut1,
            flow.user
        );

        // update cumualtives if necessary
        if (flow.forceSettleUserBalances) {
            userData[flow.user].price0Cumulative = price0CumulativeLast;
            userData[flow.user].price1Cumulative = price1CumulativeLast;
        }
    }

    function _isCFAv1(address agreementClass) private view returns (bool) {
        return ISuperAgreement(agreementClass).agreementType() == CFA_ID;
    }

    modifier onlyHost() {
        require(
            msg.sender == address(cfaV1.host),
            "RedirectAll: support only one host"
        );
        _;
    }

    modifier onlyExpected(address agreementClass) {
        require(_isCFAv1(agreementClass), "RedirectAll: only CFAv1 supported");
        _;
    }
}
