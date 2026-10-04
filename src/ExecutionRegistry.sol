// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IExecutionRegistry } from "./interfaces/IExecutionRegistry.sol";

contract ExecutionRegistry is Ownable, IExecutionRegistry {
    mapping(address adapter => bool allowed) private _adapters;

    constructor(address initialOwner) Ownable(initialOwner) { }

    function addExecutionAdapter(address adapter) external onlyOwner {
        if (adapter == address(0)) revert ZeroAddress();
        if (adapter.code.length == 0) revert NotAContract(adapter);
        if (_adapters[adapter]) revert AdapterAlreadyAdded(adapter);
        _adapters[adapter] = true;
        emit ExecutionAdapterAdded(adapter);
    }

    function removeExecutionAdapter(address adapter) external onlyOwner {
        if (!_adapters[adapter]) revert AdapterNotFound(adapter);
        _adapters[adapter] = false;
        emit ExecutionAdapterRemoved(adapter);
    }

    function isExecutionAdapter(address adapter) external view returns (bool) {
        return _adapters[adapter];
    }
}
