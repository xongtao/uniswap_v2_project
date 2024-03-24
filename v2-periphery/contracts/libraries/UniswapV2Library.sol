pragma solidity >=0.5.0;

import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";

import "./SafeMath.sol";

library UniswapV2Library {
    using SafeMath for uint;

    // 对两个的token进行排序 三目运算在工厂合约里出现过
    function sortTokens(
        address tokenA,
        address tokenB
    ) internal pure returns (address token0, address token1) {
        require(tokenA != tokenB, "UniswapV2Library: IDENTICAL_ADDRESSES");
        (token0, token1) = tokenA < tokenB
            ? (tokenA, tokenB)
            : (tokenB, tokenA);
        require(token0 != address(0), "UniswapV2Library: ZERO_ADDRESS");
    }

    /**
        @dev 获取pair合约地址 create2
        @notice 在不进行任何外部调用的情况下计算一对的CREATE2地址
        @param factory
        @param tokenA
        @param tokenB
        @return pair  返回合约地址
     */
    function pairFor(
        address factory,
        address tokenA,
        address tokenB
    ) internal pure returns (address pair) {
        (address token0, address token1) = sortTokens(tokenA, tokenB);
        pair = address(
            uint(
                keccak256(
                    abi.encodePacked(
                        //一个常量前缀，用于确保编码的独特性。
                        //常量前缀hex"ff"：这个常量是为了确保生成的是一个唯一的地址空间。在计算合约地址时，
                        //hex"ff"作为一个固定的前缀，这有助于区分地址，并确保生成的地址是独特的。
                        // factory地址：这是Uniswap工厂合约的地址。
                        //它被包含在计算中，以确保每个Uniswap工厂合约生成的配对合约地址是独立的。
                        hex"ff",
                        factory,
                        //先生成字节码，再取哈希 即salt
                        keccak256(abi.encodePacked(token0, token1)),
                        //一个特定的哈希值，用于Uniswap合约，保证地址的唯一性。
                        hex"96e8ac4277198ff8b6f785478aa9a39f403cb768dd02cbee326c3e7da348845f"
                    )
                )
            )
        );
    }

    // 获取和排序两个token储备量
    function getReserves(
        address factory,
        address tokenA,
        address tokenB
    ) internal view returns (uint reserveA, uint reserveB) {
        (address token0, ) = sortTokens(tokenA, tokenB);
        (uint reserve0, uint reserve1, ) = IUniswapV2Pair(
            pairFor(factory, tokenA, tokenB)
        ).getReserves();
        (reserveA, reserveB) = tokenA == token0
            ? (reserve0, reserve1)
            : (reserve1, reserve0);
    }

    /**
        @dev 对价计算 给定一个A的一个数额，返回可以取出的B的数额
        @return amountB  可以取出B的数额
     */
    function quote(
        uint amountA,
        uint reserveA,
        uint reserveB
    ) internal pure returns (uint amountB) {
        require(amountA > 0, "UniswapV2Library: INSUFFICIENT_AMOUNT");
        require(
            reserveA > 0 && reserveB > 0,
            "UniswapV2Library: INSUFFICIENT_LIQUIDITY"
        );
        //用粗略的交叉相乘的方式来估算 amountB * reserveA = amountA * reserveB
        amountB = amountA.mul(reserveB) / reserveA;
    }

    // 给定tokenA的输入量和储量对，返回tokenB的最大输出量
    function getAmountOut(
        uint amountIn,
        uint reserveIn,
        uint reserveOut
    ) internal pure returns (uint amountOut) {
        require(amountIn > 0, "UniswapV2Library: INSUFFICIENT_INPUT_AMOUNT");
        require(
            reserveIn > 0 && reserveOut > 0,
            "UniswapV2Library: INSUFFICIENT_LIQUIDITY"
        );
        uint amountInWithFee = amountIn.mul(997);
        uint numerator = amountInWithFee.mul(reserveOut);
        uint denominator = reserveIn.mul(1000).add(amountInWithFee);
        //还是采用粗略的交叉相乘的方法来估算 但是amountA经过了扣税 
        //tips 求B不考虑rB的变化 求谁不考虑谁的变化 只是粗略计算
        // amountOut = ( amountIn * 997 *  reserveOut ) / ( reserveIn * 1000 + amountIn * 997 )
        amountOut = numerator / denominator;
    }

    // 给定tokenA的输出量和储备对，返回tokenB所需的输入量
    function getAmountIn(
        uint amountOut,
        uint reserveIn, //reserve A
        uint reserveOut// reserve B
    ) internal pure returns (uint amountIn) {
        require(amountOut > 0, "UniswapV2Library: INSUFFICIENT_OUTPUT_AMOUNT");
        require(
            reserveIn > 0 && reserveOut > 0,
            "UniswapV2Library: INSUFFICIENT_LIQUIDITY"
        );
        uint numerator = reserveIn.mul(amountOut).mul(1000);
        uint denominator = reserveOut.sub(amountOut).mul(997);
        // rA * aB = rB * aA    已知aB,rA,rB,反求aA，则不考虑rA的变化  求谁不考虑谁的变化
        // aA = ( rA * aB * 1000 ) / (new_rB),new_rB = (rB * 1000 - aB * 997);
        // amountIn = ( reserveIn * amountOut *  1000 ) / ( reserveOut*1000 - amountB * 997 )
        amountIn = (numerator / denominator).add(1);
    }

    // 对任意数量的交易对执行链式getAmountOut计算
    // getAmountOut的连续调用
    function getAmountsOut(
        address factory,
        uint amountIn,
        address[] memory path
    ) internal view returns (uint[] memory amounts) {
        //判断path路径为多个
        require(path.length >= 2, "UniswapV2Library: INVALID_PATH");
        //amounts数组的长度为path.length
        amounts = new uint[](path.length);
        //输入数额 等于 amounts[0]
        amounts[0] = amountIn;
        //获取每个pair合约所对应的储备量
        for (uint i; i < path.length - 1; i++) {
            (uint reserveIn, uint reserveOFut) = getReserves(
                factory,
                path[i],
                path[i + 1]
            );
            amounts[i + 1] = getAmountOut(amounts[i], reserveIn, reserveOut);
        }
    }

    // 对任意数量的交易对执行链式getAmountIn计算
    // getAmountIn的连续调用
    function getAmountsIn(
        address factory,
        uint amountOut,
        address[] memory path
    ) internal view returns (uint[] memory amounts) {
        //判断path路径为多个
        require(path.length >= 2, "UniswapV2Library: INVALID_PATH");
        //amounts数组的长度为path.length
        amounts = new uint[](path.length);
        //amounts数组的最后一个为amountOut 
        amounts[amounts.length - 1] = amountOut;
        //从最后一个pair合约往前得到对应的Reserve
        for (uint i = path.length - 1; i > 0; i--) {
            (uint reserveIn, uint reserveOut) = getReserves(
                factory,
                path[i - 1],
                path[i]
            );
            //从后往前调用getAmountIn 
            //获得到的amounts在赋值到前面一位
            amounts[i - 1] = getAmountIn(amounts[i], reserveIn, reserveOut);
        }
    }
}
