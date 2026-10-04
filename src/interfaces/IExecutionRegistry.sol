// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.20;

interface IExecutionRegistry {
    error ZeroAddress();
    error AdapterAlreadyAdded(address adapter);
    error AdapterNotFound(address adapter);
    error NotAContract(address adapter);

    event ExecutionAdapterAdded(address indexed adapter);
    event ExecutionAdapterRemoved(address indexed adapter);

    function isExecutionAdapter(address adapter) external view returns (bool);
}
