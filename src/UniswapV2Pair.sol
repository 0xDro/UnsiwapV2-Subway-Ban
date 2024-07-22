pragma solidity =0.5.16;

import "./interfaces/IUniswapV2Pair.sol";
import "./UniswapV2ERC20.sol";
import "./libraries/Math.sol";
import "./libraries/UQ112x112.sol";
import "./interfaces/IERC20.sol";
import "./interfaces/IUniswapV2Factory.sol";
import "./interfaces/IUniswapV2Callee.sol";
import "./libraries/CoW.sol";

contract UniswapV2Pair is IUniswapV2Pair, UniswapV2ERC20 {
    using SafeMath for uint;
    using UQ112x112 for uint224;

    uint public constant MINIMUM_LIQUIDITY = 10 ** 3;
    bytes4 private constant SELECTOR =
        bytes4(keccak256(bytes("transfer(address,uint256)")));

    address public factory;
    address public token0;
    address public token1;

    uint112 private reserve0; // uses single storage slot, accessible via getReserves
    uint112 private reserve1; // uses single storage slot, accessible via getReserves
    uint32 private blockTimestampLast; // uses single storage slot, accessible via getReserves

    uint public price0CumulativeLast;
    uint public price1CumulativeLast;
    uint public kLast; // reserve0 * reserve1, as of immediately after the most recent liquidity event

    // CoW state
    mapping(uint256 => CoW.Orders) public orders;

    uint private unlocked = 1;
    modifier lock() {
        require(unlocked == 1, "UniswapV2: LOCKED");
        unlocked = 0;
        _;
        unlocked = 1;
    }

    function getReserves()
        public
        view
        returns (
            uint112 _reserve0,
            uint112 _reserve1,
            uint32 _blockTimestampLast
        )
    {
        _reserve0 = reserve0;
        _reserve1 = reserve1;
        _blockTimestampLast = blockTimestampLast;
    }

    function _safeTransfer(address token, address to, uint value) private {
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(SELECTOR, to, value)
        );
        require(
            success && (data.length == 0 || abi.decode(data, (bool))),
            "UniswapV2: TRANSFER_FAILED"
        );
    }

    event Mint(address indexed sender, uint amount0, uint amount1);

    event Burn(
        address indexed sender,
        uint amount0,
        uint amount1,
        address indexed to
    );
    event Swap(
        address indexed sender,
        uint amount0In,
        uint amount1In,
        uint amount0Out,
        uint amount1Out,
        address indexed to
    );
    event Sync(uint112 reserve0, uint112 reserve1);

    constructor() public {
        factory = msg.sender;
    }

    // called once by the factory at time of deployment
    function initialize(address _token0, address _token1) external {
        require(msg.sender == factory, "UniswapV2: FORBIDDEN"); // sufficient check
        token0 = _token0;
        token1 = _token1;
    }

    // update reserves and, on the first call per block, price accumulators
    function _update(
        uint balance0,
        uint balance1,
        uint112 _reserve0,
        uint112 _reserve1
    ) private {
        require(
            balance0 <= uint112(-1) && balance1 <= uint112(-1),
            "UniswapV2: OVERFLOW"
        );
        uint32 blockTimestamp = uint32(block.timestamp % 2 ** 32);
        uint32 timeElapsed = blockTimestamp - blockTimestampLast; // overflow is desired
        if (timeElapsed > 0 && _reserve0 != 0 && _reserve1 != 0) {
            // * never overflows, and + overflow is desired
            price0CumulativeLast +=
                uint(UQ112x112.encode(_reserve1).uqdiv(_reserve0)) *
                timeElapsed;
            price1CumulativeLast +=
                uint(UQ112x112.encode(_reserve0).uqdiv(_reserve1)) *
                timeElapsed;
        }
        reserve0 = uint112(balance0);
        reserve1 = uint112(balance1);
        blockTimestampLast = blockTimestamp;
        emit Sync(reserve0, reserve1);
    }

    // if fee is on, mint liquidity equivalent to 1/6th of the growth in sqrt(k)
    function _mintFee(
        uint112 _reserve0,
        uint112 _reserve1
    ) private returns (bool feeOn) {
        address feeTo = IUniswapV2Factory(factory).feeTo();
        feeOn = feeTo != address(0);
        uint _kLast = kLast; // gas savings
        if (feeOn) {
            if (_kLast != 0) {
                uint rootK = Math.sqrt(uint(_reserve0).mul(_reserve1));
                uint rootKLast = Math.sqrt(_kLast);
                if (rootK > rootKLast) {
                    uint numerator = totalSupply.mul(rootK.sub(rootKLast));
                    uint denominator = rootK.mul(5).add(rootKLast);
                    uint liquidity = numerator / denominator;
                    if (liquidity > 0) _mint(feeTo, liquidity);
                }
            }
        } else if (_kLast != 0) {
            kLast = 0;
        }
    }

    // this low-level function should be called from a contract which performs important safety checks
    function mint(address to) external lock returns (uint liquidity) {
        (uint112 _reserve0, uint112 _reserve1, ) = getReserves(); // gas savings
        uint balance0 = IERC20(token0).balanceOf(address(this));
        uint balance1 = IERC20(token1).balanceOf(address(this));
        uint amount0 = balance0.sub(_reserve0);
        uint amount1 = balance1.sub(_reserve1);

        bool feeOn = _mintFee(_reserve0, _reserve1);
        uint _totalSupply = totalSupply; // gas savings, must be defined here since totalSupply can update in _mintFee
        if (_totalSupply == 0) {
            liquidity = Math.sqrt(amount0.mul(amount1)).sub(MINIMUM_LIQUIDITY);
            _mint(address(0), MINIMUM_LIQUIDITY); // permanently lock the first MINIMUM_LIQUIDITY tokens
        } else {
            liquidity = Math.min(
                amount0.mul(_totalSupply) / _reserve0,
                amount1.mul(_totalSupply) / _reserve1
            );
        }
        require(liquidity > 0, "UniswapV2: INSUFFICIENT_LIQUIDITY_MINTED");
        _mint(to, liquidity);

        _update(balance0, balance1, _reserve0, _reserve1);
        if (feeOn) kLast = uint(reserve0).mul(reserve1); // reserve0 and reserve1 are up-to-date
        emit Mint(msg.sender, amount0, amount1);
    }

    // this low-level function should be called from a contract which performs important safety checks
    function burn(
        address to
    ) external lock returns (uint amount0, uint amount1) {
        (uint112 _reserve0, uint112 _reserve1, ) = getReserves(); // gas savings
        address _token0 = token0; // gas savings
        address _token1 = token1; // gas savings
        uint balance0 = IERC20(_token0).balanceOf(address(this));
        uint balance1 = IERC20(_token1).balanceOf(address(this));
        uint liquidity = balanceOf[address(this)];

        bool feeOn = _mintFee(_reserve0, _reserve1);
        uint _totalSupply = totalSupply; // gas savings, must be defined here since totalSupply can update in _mintFee
        amount0 = liquidity.mul(balance0) / _totalSupply; // using balances ensures pro-rata distribution
        amount1 = liquidity.mul(balance1) / _totalSupply; // using balances ensures pro-rata distribution
        require(
            amount0 > 0 && amount1 > 0,
            "UniswapV2: INSUFFICIENT_LIQUIDITY_BURNED"
        );
        _burn(address(this), liquidity);
        _safeTransfer(_token0, to, amount0);
        _safeTransfer(_token1, to, amount1);
        balance0 = IERC20(_token0).balanceOf(address(this));
        balance1 = IERC20(_token1).balanceOf(address(this));

        _update(balance0, balance1, _reserve0, _reserve1);
        if (feeOn) kLast = uint(reserve0).mul(reserve1); // reserve0 and reserve1 are up-to-date
        emit Burn(msg.sender, amount0, amount1, to);
    }

    function swap(uint amount0Out, uint amount1Out, address to) external lock {
        require(
            amount0Out > 0 || amount1Out > 0,
            "UniswapV2: INSUFFICIENT_OUTPUT_AMOUNT"
        );

        require(
            amount0Out == 0 || amount1Out == 0,
            "UniswapV2: INVALID_AMOUNT_OUT"
        );

        if (_checkIsNewBlock()) {
            _settleRemainder();
            delete orders[block.number - 1];
        }

        if (_canExecuteCoW(amount0Out, amount1Out)) {
            if (amount0Out > 0) {
                _performToken0CoWMatching(to, amount0Out);
            } else {
                _performToken1CoWMatching(to, amount1Out);
            }
        } else {
            _pushNewOrderForCoW(amount0Out, amount1Out);
        }
    }

    function _checkIsNewBlock() internal view returns (bool) {
        uint256 blockNum = block.number;
        if (orders[blockNum].blockNum == 0) {
            return true;
        }
    }

    function _settleRemainder() internal {
        CoW.Orders storage prevBlockOrders = orders[block.number - 1];
        for (uint i = 0; i < prevBlockOrders.orders.length; i++) {
            CoW.Order memory order = prevBlockOrders.orders[i];
            // check requirments so the next call cannot fail, if it would fail, refund and move onto next order
            if (_canMakeValidAmmSwap()) {
                _ammSwap(order.amount0Out, order.amount1Out, order.taker, "");
            } else {
                _refundTrader();
            }
        }
    }

    function settleRemainder() external lock {
        if (_checkIsNewBlock()) {
            _settleRemainder();
        }
    }

    function _refundTrader() internal {}

    function _canMakeValidAmmSwap() internal view returns (bool) {
        return true;
    }

    function _canExecuteCoW(
        uint256 amount0Out,
        uint256 amount1Out
    ) internal view returns (bool) {
        uint256 blockNum = block.number;
        CoW.Orders memory currentOrders = orders[blockNum];
        if (amount0Out > 0 && currentOrders.totalAmount1Out > 0) {
            return true;
        }
        if (amount1Out > 0 && currentOrders.totalAmount0Out > 0) {
            return true;
        }
        return false;
    }

    function _pushNewOrderForCoW(uint amount0Out, uint amount1Out) internal {
        CoW.Orders storage currentOrders = orders[block.number];
        CoW.Order memory newOrder = CoW.Order({
            taker: msg.sender,
            amount0Out: amount0Out,
            amount1Out: amount1Out
        });

        currentOrders.orders.push(newOrder);
        currentOrders.totalAmount0Out = currentOrders.totalAmount0Out.add(
            amount0Out
        );
        currentOrders.totalAmount1Out = currentOrders.totalAmount1Out.add(
            amount1Out
        );
    }

    function _performToken0CoWMatching(address taker, uint256 amount) internal {
        if (amount == 0) {
            return;
        }
        CoW.Orders storage currentOrders = orders[block.number];
        (uint112 _reserve0, uint112 _reserve1, ) = getReserves();
        uint256 exchangeRate = uint256(_reserve1).mul(1e18).div(_reserve0); // token1 per token0

        for (uint i = 0; i < currentOrders.orders.length; i++) {
            CoW.Order memory order = currentOrders.orders[i];
            uint256 amount1Out = order.amount1Out;
            if (amount1Out > 0) {
                uint256 equivalentAmount1 = amount.mul(exchangeRate).div(1e18);
                if (amount1Out > equivalentAmount1) {
                    _safeTransfer(token0, taker, amount);
                    _safeTransfer(token1, order.taker, equivalentAmount1);
                    currentOrders.totalAmount0Out = currentOrders
                        .totalAmount0Out
                        .sub(amount);
                    currentOrders.totalAmount1Out = currentOrders
                        .totalAmount1Out
                        .sub(equivalentAmount1);
                    order.amount1Out = order.amount1Out.sub(equivalentAmount1);
                    currentOrders.orders[i] = order;
                    amount = 0;
                    break;
                } else {
                    uint256 equivalentAmount0 = amount1Out.mul(1e18).div(
                        exchangeRate
                    );
                    _safeTransfer(token0, taker, equivalentAmount0);
                    _safeTransfer(token1, order.taker, amount1Out);
                    currentOrders.totalAmount0Out = currentOrders
                        .totalAmount0Out
                        .sub(equivalentAmount0);
                    currentOrders.totalAmount1Out = currentOrders
                        .totalAmount1Out
                        .sub(amount1Out);
                    amount = amount.sub(equivalentAmount0);
                    order.amount1Out = 0;
                    delete currentOrders.orders[i];
                }
            }
        }

        // push remainder to orders
        if (amount > 0) {
            _pushNewOrderForCoW(amount, 0);
        }
    }
    function _performToken1CoWMatching(address taker, uint256 amount) internal {
        if (amount == 0) {
            return;
        }
        CoW.Orders storage currentOrders = orders[block.number];
        (uint112 _reserve0, uint112 _reserve1, ) = getReserves();
        uint256 exchangeRate = uint256(_reserve0).mul(1e18).div(_reserve1); // token0 per token1

        for (uint i = 0; i < currentOrders.orders.length; i++) {
            CoW.Order memory order = currentOrders.orders[i];
            uint256 amount0Out = order.amount0Out;
            if (amount0Out > 0) {
                uint256 equivalentAmount0 = amount.mul(exchangeRate).div(1e18);
                if (amount0Out > equivalentAmount0) {
                    _safeTransfer(token1, taker, amount);
                    _safeTransfer(token0, order.taker, equivalentAmount0);
                    currentOrders.totalAmount1Out = currentOrders
                        .totalAmount1Out
                        .sub(amount);
                    currentOrders.totalAmount0Out = currentOrders
                        .totalAmount0Out
                        .sub(equivalentAmount0);
                    order.amount0Out = order.amount0Out.sub(equivalentAmount0);
                    currentOrders.orders[i] = order;
                    amount = 0;
                    break;
                } else {
                    uint256 equivalentAmount1 = amount0Out.mul(1e18).div(
                        exchangeRate
                    );
                    _safeTransfer(token1, taker, equivalentAmount1);
                    _safeTransfer(token0, order.taker, amount0Out);
                    currentOrders.totalAmount1Out = currentOrders
                        .totalAmount1Out
                        .sub(equivalentAmount1);
                    currentOrders.totalAmount0Out = currentOrders
                        .totalAmount0Out
                        .sub(amount0Out);
                    amount = amount.sub(equivalentAmount1);
                    order.amount0Out = 0;
                    delete currentOrders.orders[i];
                }
            }
        }

        // push remainder to orders if there is any leftover amount1
        if (amount > 0) {
            _pushNewOrderForCoW(0, amount);
        }
    }

    // this low-level function should be called from a contract which performs important safety checks
    function _ammSwap(
        uint amount0Out,
        uint amount1Out,
        address to,
        bytes memory data
    ) internal lock {
        require(
            amount0Out > 0 || amount1Out > 0,
            "UniswapV2: INSUFFICIENT_OUTPUT_AMOUNT"
        );
        (uint112 _reserve0, uint112 _reserve1, ) = getReserves(); // gas savings
        require(
            amount0Out < _reserve0 && amount1Out < _reserve1,
            "UniswapV2: INSUFFICIENT_LIQUIDITY"
        );

        uint balance0;
        uint balance1;
        {
            // scope for _token{0,1}, avoids stack too deep errors
            address _token0 = token0;
            address _token1 = token1;
            require(to != _token0 && to != _token1, "UniswapV2: INVALID_TO");
            if (amount0Out > 0) _safeTransfer(_token0, to, amount0Out); // optimistically transfer tokens
            if (amount1Out > 0) _safeTransfer(_token1, to, amount1Out); // optimistically transfer tokens
            if (data.length > 0)
                IUniswapV2Callee(to).uniswapV2Call(
                    msg.sender,
                    amount0Out,
                    amount1Out,
                    data
                );
            balance0 = IERC20(_token0).balanceOf(address(this));
            balance1 = IERC20(_token1).balanceOf(address(this));
        }
        uint amount0In = balance0 > _reserve0 - amount0Out
            ? balance0 - (_reserve0 - amount0Out)
            : 0;
        uint amount1In = balance1 > _reserve1 - amount1Out
            ? balance1 - (_reserve1 - amount1Out)
            : 0;
        require(
            amount0In > 0 || amount1In > 0,
            "UniswapV2: INSUFFICIENT_INPUT_AMOUNT"
        );
        {
            // scope for reserve{0,1}Adjusted, avoids stack too deep errors
            uint balance0Adjusted = balance0.mul(1000).sub(amount0In.mul(3));
            uint balance1Adjusted = balance1.mul(1000).sub(amount1In.mul(3));
            require(
                balance0Adjusted.mul(balance1Adjusted) >=
                    uint(_reserve0).mul(_reserve1).mul(1000 ** 2),
                "UniswapV2: K"
            );
        }

        _update(balance0, balance1, _reserve0, _reserve1);
        emit Swap(msg.sender, amount0In, amount1In, amount0Out, amount1Out, to);
    }

    // force balances to match reserves
    function skim(address to) external lock {
        address _token0 = token0; // gas savings
        address _token1 = token1; // gas savings
        _safeTransfer(
            _token0,
            to,
            IERC20(_token0).balanceOf(address(this)).sub(reserve0)
        );
        _safeTransfer(
            _token1,
            to,
            IERC20(_token1).balanceOf(address(this)).sub(reserve1)
        );
    }

    // force reserves to match balances
    function sync() external lock {
        _update(
            IERC20(token0).balanceOf(address(this)),
            IERC20(token1).balanceOf(address(this)),
            reserve0,
            reserve1
        );
    }
}
