// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { ISystemContract } from "@reactive/src/interfaces/ISystemContract.sol";
import { IReactive } from "@reactive/src/interfaces/IReactive.sol";
import { IPayer } from "@reactive/src/interfaces/IPayer.sol";

/// @title MockSystemContract
/// @notice Faithful test mock of Reactive Omni's SYSTEM contract deployed at
///         0x8888888888888888888888888888888888888888 via `vm.etch` in Foundry tests.
contract MockSystemContract is ISystemContract {
    struct Subscription {
        address subscriber;
        uint256 chainId;
        address contractAddress;
        uint256 topic0;
        uint256 topic1;
        uint256 topic2;
        uint256 topic3;
        bool active;
    }

    struct QueuedCallback {
        address sender;
        uint256 chainId;
        address recipient;
        uint64 gasLimit;
        bytes payload;
    }

    event Subscribed(address indexed subscriber, uint256 indexed chainId, address indexed contractAddress, uint256 topic0);
    event Unsubscribed(address indexed subscriber, uint256 indexed chainId, address indexed contractAddress, uint256 topic0);
    event CallbackRequest(
        uint256 indexed chainId,
        address indexed sender,
        address indexed recipient,
        CallbackVersion version,
        bytes configuration
    );

    mapping(bytes32 => Subscription) public subscriptions;
    mapping(address => uint256) public activeSubscriptionCount;
    mapping(address => uint256) public debts;
    mapping(address => uint256) public reserves;

    QueuedCallback[] public queuedCallbacks;

    receive() external payable override {
        uint256 owed = debts[msg.sender];
        if (msg.value >= owed) {
            debts[msg.sender] = 0;
            reserves[msg.sender] += msg.value - owed;
        } else {
            debts[msg.sender] = owed - msg.value;
        }
    }

    function depositTo(address target_) external payable {
        uint256 owed = debts[target_];
        if (msg.value >= owed) {
            debts[target_] = 0;
            reserves[target_] += msg.value - owed;
        } else {
            debts[target_] = owed - msg.value;
        }
    }

    function debt(address contract_) external view override returns (uint256) {
        return debts[contract_];
    }

    function setDebt(address contract_, uint256 amount_) external {
        debts[contract_] = amount_;
    }

    function charge(address payer_, uint256 amount_) external {
        IPayer(payable(payer_)).pay(amount_);
    }

    function subscribe(
        uint256 chainId_,
        address contract_,
        uint256 topic0_,
        uint256 topic1_,
        uint256 topic2_,
        uint256 topic3_
    ) external override {
        bytes32 key = keccak256(abi.encode(msg.sender, chainId_, contract_, topic0_, topic1_, topic2_, topic3_));
        if (!subscriptions[key].active) {
            subscriptions[key] = Subscription({
                subscriber: msg.sender,
                chainId: chainId_,
                contractAddress: contract_,
                topic0: topic0_,
                topic1: topic1_,
                topic2: topic2_,
                topic3: topic3_,
                active: true
            });
            activeSubscriptionCount[msg.sender] += 1;
            emit Subscribed(msg.sender, chainId_, contract_, topic0_);
        }
    }

    function unsubscribe(
        uint256 chainId_,
        address contract_,
        uint256 topic0_,
        uint256 topic1_,
        uint256 topic2_,
        uint256 topic3_
    ) external override {
        bytes32 key = keccak256(abi.encode(msg.sender, chainId_, contract_, topic0_, topic1_, topic2_, topic3_));
        if (subscriptions[key].active) {
            subscriptions[key].active = false;
            activeSubscriptionCount[msg.sender] -= 1;
            emit Unsubscribed(msg.sender, chainId_, contract_, topic0_);
        }
    }

    function requestCallback(CallbackVersion version_, bytes memory config_) external override {
        require(version_ == CallbackVersion.V_1_0, "InvalidCallbackVersion");
        CallbackConfiguration_V_1_0 memory cfg = abi.decode(config_, (CallbackConfiguration_V_1_0));
        _enqueue(cfg, config_);
    }

    function requestCallbackV_1_0(CallbackConfiguration_V_1_0 memory config_) external override {
        _enqueue(config_, abi.encode(config_));
    }

    function _enqueue(CallbackConfiguration_V_1_0 memory cfg_, bytes memory encodedCfg_) internal {
        queuedCallbacks.push(
            QueuedCallback({
                sender: msg.sender,
                chainId: cfg_.chainId,
                recipient: cfg_.recipient,
                gasLimit: cfg_.gasLimit,
                payload: cfg_.payload
            })
        );
        emit CallbackRequest(cfg_.chainId, msg.sender, cfg_.recipient, CallbackVersion.V_1_0, encodedCfg_);
    }

    /// @notice Delivers a log record to a subscribed Reactive contract just as Reactive Omni validators do.
    function trigger(address reactiveContract_, IReactive.LogRecord calldata log_) external {
        IReactive(payable(reactiveContract_)).react(log_);
    }

    function getQueuedCallbackCount() external view returns (uint256) {
        return queuedCallbacks.length;
    }

    function getQueuedCallback(uint256 index_) external view returns (QueuedCallback memory) {
        return queuedCallbacks[index_];
    }
}
