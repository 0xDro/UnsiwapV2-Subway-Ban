pragma solidity =0.5.16;

// types for storing intra-block orders to fulfill CoW

library CoW {
    struct Order {
        address taker;
        uint256 amount0Out;
        uint256 amount1Out;
    }

    struct Orders {
        Order[] orders;
        uint256 blockNum;
        uint256 totalAmount0Out;
        uint256 totalAmount1Out;
    }
}
