// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

interface ICore {
    function buyByBudget(address token, uint256 maxPayAmount, uint256 minAmountOut, uint256 options, bytes calldata proof)
        external
        payable;

    function sell(address token, uint256 amount, uint256 minAmountOut, uint256 options, bytes calldata proof) external;
}

interface IERC20Min {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
}

/// @notice Tiny terminal-style forwarder used only in the demo: buys on behalf of the caller so that
///         `ctx.trader` is a contract and the trade module must resolve the wallet via tx.origin.
contract DemoRouter {
    ICore public immutable CORE;

    constructor(ICore core_) {
        CORE = core_;
    }

    function buyFor(address token, uint256 budget) external payable {
        uint256 tokBefore = IERC20Min(token).balanceOf(address(this));
        uint256 ethBefore = address(this).balance - msg.value;
        CORE.buyByBudget{value: msg.value}(token, budget, 0, 0, "");
        uint256 got = IERC20Min(token).balanceOf(address(this)) - tokBefore;
        // Hand-off of exactly the just bought tokens to the signer is free before migration: the token credits the
        // router for what it received from the vault/Core in this tx and exempts a transfer up to that amount.
        require(got > 0, "no tokens bought");
        require(IERC20Min(token).transfer(msg.sender, got), "hand-off failed");
        uint256 refund = address(this).balance - ethBefore;
        if (refund > 0) {
            (bool ok,) = msg.sender.call{value: refund}("");
            require(ok, "refund");
        }
    }

    /// @notice Sells `amount` of the caller's tokens through Core. The router pulls them from the signer first; that
    ///         pull is free of the transfer fee only if this router is on the registry allowlist, so the sale reverts
    ///         for an unlisted router (it would receive less than `amount`).
    function sellFor(address token, uint256 amount) external {
        uint256 tokBefore = IERC20Min(token).balanceOf(address(this));
        uint256 ethBefore = address(this).balance;
        require(IERC20Min(token).transferFrom(msg.sender, address(this), amount), "pull failed");
        uint256 got = IERC20Min(token).balanceOf(address(this)) - tokBefore;
        require(got == amount, "router not allowlisted");
        require(IERC20Min(token).approve(address(CORE), got), "approve failed");
        CORE.sell(token, got, 0, 0, "");
        uint256 proceeds = address(this).balance - ethBefore;
        if (proceeds > 0) {
            (bool ok,) = msg.sender.call{value: proceeds}("");
            require(ok, "refund");
        }
    }

    receive() external payable {}
}
