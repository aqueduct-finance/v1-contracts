// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

library Math {
    // computes the absolute difference between two unsigned values
    function difference(uint256 x, uint256 y) internal pure returns (uint256) {
        return x > y ? x - y : y - x;
    }

    // computes the absolute difference between two signed values
    function signedDifference(int96 x, int96 y) internal pure returns (int96) {
        return x > y ? x - y : y - x;
    }

    function safeUnsignedAdd(uint128 a, int96 b)
        internal
        pure
        returns (uint128)
    {
        // TODO: this can still technically underflow, add try/catch?
        // This is used for computing pool net flow, which should never be < 0
        return b < 0 ? a - uint96(b * -1) : a + uint96(b);
    }
}
