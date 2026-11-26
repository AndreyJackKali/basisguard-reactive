// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { IPayer } from "@reactive/src/interfaces/IPayer.sol";

/// @title MockCallbackProxy
/// @notice Faithful test mock of Reactive Omni's destination Callback Proxy.
///         Overwrites the first 160-bit address argument of the callback payload (bytes 16..35)
///         with the authentic reactive contract address before invoking the destination recipient.
contract MockCallbackProxy is IPayable {
    error PayloadTooShort();
    error CallbackExecutionFailed(bytes revertData);

    mapping(address => uint256) public debts;
    mapping(address => uint256) public reserves;

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

    /// @notice Delivers a Reactive Omni callback by overwriting the first ABI argument with `reactiveSender_`.
    function deliverCallback(address reactiveSender_, address recipient_, bytes memory payload_)
        external
        returns (bytes memory ret_)
    {
        if (payload_.length < 36) revert PayloadTooShort();

        // Overwrite bytes [4..36) (first 32-byte ABI word after 4-byte selector) with left-padded reactiveSender_.
        bytes32 injected = bytes32(uint256(uint160(reactiveSender_)));
        assembly {
            mstore(add(payload_, 36), injected)
        }

        (bool ok, bytes memory res) = recipient_.call(payload_);
        if (!ok) {
            assembly {
                revert(add(res, 32), mload(res))
            }
        }
        return res;
    }
}
