// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

interface IERC20Pull {
    function transferFrom(address, address, uint256) external returns (bool);
}

/// @notice Demo only, never to be allowlisted: pulls tokens from the caller and keeps them (a custody contract). Used to
///         show that a contract outside the registry's router allowlist pays the transfer fee on the pull.
contract CustodyMock {
    function pullFrom(address token, uint256 amount) external {
        require(IERC20Pull(token).transferFrom(msg.sender, address(this), amount), "pull failed");
    }
}
