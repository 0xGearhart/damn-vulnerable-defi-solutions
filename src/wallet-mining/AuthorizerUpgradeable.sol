// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

contract AuthorizerUpgradeable {
    // @audit Upgradable contracts cannot have their state variables set in the implementation contract, they must be initialized at deployment time with a delegatecall through the proxy contract to be saved in the proxy contracts storage.
    uint256 public needsInit = 1;
    mapping(address => mapping(address => uint256)) private wards;

    event Rely(address indexed usr, address aim);

    // @audit Upgradable contracts cannot use constructors, they need to implement initialization type functions that are called at proxy deployment time.
    // Otherwise, state is only set within the implementation contract instead of the proxy contract where all state should be stored.
    constructor() {
        needsInit = 0; // freeze implementation
    }

    // @audit Critical - Missing Access Controls / Initializer Not Disabled After Deployment
    // This function can be called by anyone, even though initialization is supposedly disabled by constructor.
    // This allows anyone to assign any ward to any aim which bypasses the intended functionality of this contract.
    function init(address[] memory _wards, address[] memory _aims) external {
        require(needsInit != 0, "cannot init");
        for (uint256 i = 0; i < _wards.length; i++) {
            _rely(_wards[i], _aims[i]);
        }
        needsInit = 0;
    }

    function _rely(address usr, address aim) private {
        wards[usr][aim] = 1;
        emit Rely(usr, aim);
    }

    function can(address usr, address aim) external view returns (bool) {
        return wards[usr][aim] == 1;
    }
}
