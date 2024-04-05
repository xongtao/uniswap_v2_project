pragma solidity =0.6.6;

import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";
import "@uniswap/lib/contracts/libraries/TransferHelper.sol";

import "./libraries/UniswapV2Library.sol";
import "./interfaces/IUniswapV2Router01.sol";
import "./interfaces/IERC20.sol";
import "./interfaces/IWETH.sol";

contract UniswapV2Router01 is IUniswapV2Router01 {
    address public immutable override factory;
    address public immutable override WETH;

    modifier ensure(uint deadline) {
        require(deadline >= block.timestamp, "UniswapV2Router: EXPIRED");
        _;
    }

    constructor(address _factory, address _WETH) public {
        factory = _factory;
        WETH = _WETH;
    }

    receive() external payable {
        assert(msg.sender == WETH); // only accept ETH via fallback from the WETH contract
    }

    // **** ADD LIQUIDITY ****
    /**
        @dev 添加流动性的私有方法
        @param amountADesired 期望数量 A
        @param amountBDesired 期望数量 B
        @param amountAmin 最小期望数量A
        @param amountBmin 最小期望数量B
        @return  amountA  如果成功返回A的数量
        @return  amountB  如果成功返回B的数量 
     */
    function _addLiquidity(
        address tokenA,
        address tokenB,
        uint amountADesired, 
        uint amountBDesired,
        uint amountAMin,  
        uint amountBMin   
    ) private returns (uint amountA, uint amountB) {
        // 如果tokenA,tokenB的配对合约不存在
        if (IUniswapV2Factory(factory).getPair(tokenA, tokenB) == address(0)) {
            //则调用工厂接口合约创建pair合约
            IUniswapV2Factory(factory).createPair(tokenA, tokenB);
        }
        // 获取tokenA,tokenB的储备量
        (uint reserveA, uint reserveB) = UniswapV2Library.getReserves(
            factory,
            tokenA,
            tokenB
        );
        //如果储备量为0，即新建的pair合约
        // 数量amount{A,B} = 期望数量 A，B
        if (reserveA == 0 && reserveB == 0) {
            (amountA, amountB) = (amountADesired, amountBDesired);
        } else {
            //最优数量B = 期望数量A * 储备B /储备A
            uint amountBOptimal = UniswapV2Library.quote(
                amountADesired,
                reserveA,
                reserveB
            );
            //如果最优数量B <= 期望数量
            if (amountBOptimal <= amountBDesired) {
                require(
                    //最优数量B >= 最小数量B
                    amountBOptimal >= amountBMin,
                    "UniswapV2Router: INSUFFICIENT_B_AMOUNT"
                );
                //数量{A,B} = 期待数量{A,B}
                (amountA, amountB) = (amountADesired, amountBOptimal);
            } else {
                //最优数量A = 期望数量B * 储备A/储备B
                uint amountAOptimal = UniswapV2Library.quote(
                    amountBDesired,
                    reserveB,
                    reserveA
                );
                //断言最优数量A <= 期望数量A
                assert(amountAOptimal <= amountADesired);
                //最优数量A  >= 数量A
                require(
                    amountAOptimal >= amountAMin,
                    "UniswapV2Router: INSUFFICIENT_A_AMOUNT"
                );
                (amountA, amountB) = (amountAOptimal, amountBDesired);
            }
        }
    }

    /**
        @dev 添加流动性的外部调用 
        @param deadline 最后期限 一般是区块结束之前
     */
    function addLiquidity(
        address tokenA,
        address tokenB,
        uint amountADesired,
        uint amountBDesired,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    )
        external
        override
        ensure(deadline)
        returns (uint amountA, uint amountB, uint liquidity)
    {
        (amountA, amountB) = _addLiquidity(
            tokenA,
            tokenB,
            amountADesired,
            amountBDesired,
            amountAMin,
            amountBMin
        );
        //获取pair 合约地址
        address pair = UniswapV2Library.pairFor(factory, tokenA, tokenB);
        //将数量amontA的tokenA从msg.sender发送给pair合约
        TransferHelper.safeTransferFrom(tokenA, msg.sender, pair, amountA);

        TransferHelper.safeTransferFrom(tokenB, msg.sender, pair, amountB);
        //流动性数量 =  pair 合约的铸造方法铸造给to地址的返回值
        liquidity = IUniswapV2Pair(pair).mint(to);
    }

    /**
        @dev 添加eth流动性方法 自动将eth转换为weth
        @param 
     */
    function addLiquidityETH(
        address token,
        uint amountTokenDesired,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    )
        external
        payable
        override
        ensure(deadline)
        returns (uint amountToken, uint amountETH, uint liquidity)
    {
        (amountToken, amountETH) = _addLiquidity(
            token,
            WETH,
            amountTokenDesired,
            msg.value,
            amountTokenMin,
            amountETHMin
        );
        address pair = UniswapV2Library.pairFor(factory, token, WETH);
        TransferHelper.safeTransferFrom(token, msg.sender, pair, amountToken);
        IWETH(WETH).deposit{value: amountETH}();
        assert(IWETH(WETH).transfer(pair, amountETH));
        liquidity = IUniswapV2Pair(pair).mint(to);
        if (msg.value > amountETH)
            TransferHelper.safeTransferETH(msg.sender, msg.value - amountETH); // refund dust eth, if any
    }

    // **** REMOVE LIQUIDITY ****
    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint liquidity,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) public override ensure(deadline) returns (uint amountA, uint amountB) {
        address pair = UniswapV2Library.pairFor(factory, tokenA, tokenB);
        IUniswapV2Pair(pair).transferFrom(msg.sender, pair, liquidity); // send liquidity to pair
        (uint amount0, uint amount1) = IUniswapV2Pair(pair).burn(to);
        (address token0, ) = UniswapV2Library.sortTokens(tokenA, tokenB);
        (amountA, amountB) = tokenA == token0
            ? (amount0, amount1)
            : (amount1, amount0);
        require(
            amountA >= amountAMin,
            "UniswapV2Router: INSUFFICIENT_A_AMOUNT"
        );
        require(
            amountB >= amountBMin,
            "UniswapV2Router: INSUFFICIENT_B_AMOUNT"
        );
    }
    function removeLiquidityETH(
        address token,
        uint liquidity,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    )
        public
        override
        ensure(deadline)
        returns (uint amountToken, uint amountETH)
    {
        (amountToken, amountETH) = removeLiquidity(
            token,
            WETH,
            liquidity,
            amountTokenMin,
            amountETHMin,
            address(this),
            deadline
        );
        TransferHelper.safeTransfer(token, to, amountToken);
        IWETH(WETH).withdraw(amountETH);
        TransferHelper.safeTransferETH(to, amountETH);
    }

    /**
        @dev 带签名移除流动性
        @param approveMax 全部批准
     */
    function removeLiquidityWithPermit(
        address tokenA,
        address tokenB,
        uint liquidity,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline,
        bool approveMax,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external override returns (uint amountA, uint amountB) {
        //creat2计算合约地址tokenA,tokenB的合约地址
        address pair = UniswapV2Library.pairFor(factory, tokenA, tokenB);
        //如果全部批准，value 等于 最大unit256,否则等于流动性
        uint value = approveMax ? uint(-1) : liquidity;
        //调用pair合约的许可方法(调用账户，当前合约地址，数值，最后期限，v,r,s)
        IUniswapV2Pair(pair).permit(
            msg.sender,
            address(this),
            value,
            deadline,
            v,
            r,
            s
        );
        // ()
        (amountA, amountB) = removeLiquidity(
            tokenA,
            tokenB,
            liquidity,
            amountAMin,
            amountBMin,
            to,
            deadline
        );
    }
    function  (
        address token,
        uint liquidity,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline,
        bool approveMax,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external override returns (uint amountToken, uint amountETH) {
        address pair = UniswapV2Library.pairFor(factory, token, WETH);
        uint value = approveMax ? uint(-1) : liquidity;
        IUniswapV2Pair(pair).permit(
            msg.sender,
            address(this),
            value,
            deadline,
            v,
            r,
            s
        );
        (amountToken, amountETH) = removeLiquidityETH(
            token,
            liquidity,
            amountTokenMin,
            amountETHMin,
            to,
            deadline
        );
    }

    // **** SWAP ****
    //swap共有 6种 方法 
    // Token --  Token
    // ETH   --  Token
    // Token --  ETH
    //再分别 确认输入还是输出(Exact) 3*2 = 6
    // 要求初始金额已发送至第一对pair合约中
    /**
        @dev 私有的交换方法
        @param amounts 填入amounts数组和
     */
    
    function _swap(
        uint[] memory amounts,
        address[] memory path,
        address _to
    ) private {
        //遍历path路径 ，unit i 默认i 为0； 
        for (uint i; i < path.length - 1; i++) {
            //确认输入token ,与 输出token 
            (address input, address output) = (path[i], path[i + 1]);
            //将input token 与 output token 排序，得到与pair合约调用相同的顺序,确保交换方向正确
            //用token0去交换所需代币 只获取其中一边的地址，另一边则为0；
            (address token0, ) = UniswapV2Library.sortTokens(input, output);
            //获取需要交换出的 output token 的数量 
            uint amountOut = maounts[i + 1];
            //如果input 恰好是 token0 ，那么amountOut 就赋值给amount1Out另一边， amount0Ount就为0 
            //这样就会判断 使用 input 交换 output
            //反之如果input 不是 token0,那么output是 token0 , 我们要拿去转化的代币在output的一边
            // 我们需要将 amount1put设置为0 ，amountOut 就会赋值给amount0Out，
            // 这样合约就会判断 用output去换input 
            (uint amount0Out, uint amount1Out) = input == token0
                ? (uint(0), amountOut)
                : (amountOut, uint(0));

            //判断是否为交换路径最后一次 如果是最后一次 交换后收款地址直接为_to
            //如果不是 交易后收款地址则为下一个交易对的pair合约地址
            address to = i < path.length -  2
                ? UniswapV2Library.pairFor(factory, output, path[i + 2])
                : _to;
            //调用pair合约进行交换，查看amount0Out和amount1Out取出数额哪个不为0；
            //从而最终输出的是哪边token
            IUniswapV2Pair(UniswapV2Library.pairFor(factory, input, output))
                .swap(amount0Out, amount1Out, to, new bytes(0));
        }
    }

    /**
        @dev 根据精确的token交换尽量多的token 给定输入 求输出
        @param amountIn 精确输入数额
        @param path 路径数组
     */
    function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external override ensure(deadline) returns (uint[] memory amounts) {
        //获取到能获得 最终token的数量 
        amounts = UniswapV2Library.getAmountsOut(factory, amountIn, path);
        //确认数组的最后一个输出数额 >= 最小输出数额
        require(
            amounts[amounts.length - 1] >= amountOutMin,
            "UniswapV2Router: INSUFFICIENT_OUTPUT_AMOUNT"
        );
        //将path[0],amount[0]的token从调用者账户发送到路径0，1的pair合约
        TransferHelper.safeTransferFrom(
            path[0],
            msg.sender,
            UniswapV2Library.pairFor(factory, path[0], path[1]),
            amounts[0]
        );
        //调用私有_swap方法进行数组遍历的swap
        _swap(amounts, path, to);
    }
    
    /**
        @dev 使用尽量少的token交换 具体数额的token  给定输出 求输入
     */
    function swapTokensForExactTokens(
        uint amountOut, //限定输出
        uint amountInMax,  //最大输入数额
        address[] calldata path,
        address to,
        uint deadline
    ) external override ensure(deadline) returns (uint[] memory amounts) {
        amounts = UniswapV2Library.getAmountsIn(factory, amountOut, path);
        //确保最终输入数额 小于 预期最大值
        require(
            amounts[0] <= amountInMax,
            "UniswapV2Router: EXCESSIVE_INPUT_AMOUNT"
        );
        //由msg.sender 向 path[0],path[1]的pair合约 发送数量为amounts[0]的token path[0] 代币
        //此函数封装了回退方法 
        TransferHelper.safeTransferFrom(
            path[0],  //token合约地址，表述输入token的类型
            msg.sender,  //发送方
            UniswapV2Library.pairFor(factory, path[0], path[1]),  //输出到 path[0,1]所对应的配对合约
            amounts[0]   //转账数量
        );
        _swap(amounts, path, to);
    }

    /** 
        @dev 根据精确的eth交换token  给定精确的ETH输入  求token的输出
        payable 表示能接受eth作为输入
     */
    function  (
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    )
        external
        payable
        override
        ensure(deadline)
        returns (uint[] memory amounts)
    {   
        //确认第一个路径为WETH
        require(path[0] == WETH, "UniswapV2Router: INVALID_PATH");
        //经过getAmountsOut得到amounts  
        amounts = UniswapV2Library.getAmountsOut(factory, msg.value, path);
        //确保最后的一个amounts >= 预期最小获得数量
        require(
            amounts[amounts.length - 1] >= amountOutMin,
            "UniswapV2Router: INSUFFICIENT_OUTPUT_AMOUNT"
        );
        //将数额amount[0] 的ETH 发送到weth合约
        //IWETH(WETH).deposit WETH是一个合约地址，意思是将WETH转换为IWETH类型，从而调用IWETH接口的deposit方法
        IWETH(WETH).deposit{value: amounts[0]}();
        //
        //可以从WETH合约发送WETH发送到path[0],path[1]所对应的pair合约
        //assert 用于检查函数内部调用出现的错误
        //require 用于外部条件判断   
        //两者都可以回滚
        assert(
            IWETH(WETH).transfer(
                UniswapV2Library.pairFor(factory, path[0], path[1]),
                amounts[0]
            )
        );
        //发送后 到pair合约就可以执行私有方法_swap 
        _swap(amounts, path, to);
    }

    /**
        @dev 使用尽量少的token交换精确的ETH  给定精确的ETH输出 求token的输入
     */
    function swapTokensForExactETH(
        uint amountOut,
        uint amountInMax,
        address[] calldata path,
        address to,
        uint deadline
    ) external override ensure(deadline) returns (uint[] memory amounts) {
        //从最后一个path[path.length]查看最后一个路径是否为WETH；
        require(path[path.length - 1] == WETH, "UniswapV2Router: INVALID_PATH");
        //调用从后往前求amounts的方法，求第一个token的数额；
        amounts = UniswapV2Library.getAmountsIn(factory, amountOut, path);
        //确保最后的amounts小于预期的amountInMax
        require(
            amounts[0] <= amountInMax,
            "UniswapV2Router: EXCESSIVE_INPUT_AMOUNT"
        );
        //将数量为amounts[0]的path[0] token 由msg.sneder发送到path[0],path[1]所对应的pair合约开始进行_swap
        //实际还是从前往后调用  
        TransferHelper.safeTransferFrom(
            path[0], //from地址
            msg.sender, 
            UniswapV2Library.pairFor(factory, path[0], path[1]),
            amounts[0]
        );
        //_swap的最终收WETH的地址为当前路由合约
        //然后WETH pair合约中可以取出等量的ETH
        _swap(amounts, path, address(this));
        //从WETH合约取出 amouts[amounts.length-1]的ETH
        IWETH(WETH).withdraw(amounts[amounts.length - 1]);
        //将amouts[amounts.length-1]的ETH 转入到to地址
        TransferHelper.safeTransferETH(to, amounts[amounts.length - 1]);
    }

    /**
        @dev 根据精确token 交换更多的eth  给定精确的token的输入 求ETH的输出
     */
    function swapExactTokensForETH(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external override ensure(deadline) returns (uint[] memory amounts) {
        //判断最后输出的token为weth
        require(path[path.length - 1] == WETH, "UniswapV2Router: INVALID_PATH");
        //通过path数组和amountsIn，获取amounts数组
        amounts = UniswapV2Library.getAmountsOut(factory, amountIn, path);
        require(
            amounts[amounts.length - 1] >= amountOutMin,
            "UniswapV2Router: INSUFFICIENT_OUTPUT_AMOUNT"
        );
        TransferHelper.safeTransferFrom(
            path[0],
            msg.sender,
            UniswapV2Library.pairFor(factory, path[0], path[1]),
            amounts[0]
        );
        //_swap的最终收WETH的地址为当前路由合约
        //然后WETH pair合约中可以取出等量的ETH
        _swap(amounts, path, address(this));
        //区别于tokentotoken ,tokentoETH最后一步需要通过WETH合约换成ETH
        IWETH(WETH).withdraw(amounts[amounts.length - 1]);
        TransferHelper.safeTransferETH(to, amounts[amounts.length - 1]);
    }

    /** 
        @dev 使用尽量少的ETH交换更多的token数量  给定精确的ETH的输出  求token的输入
        payable 表示能接受eth作为输入
     */
    function swapETHForExactTokens(
        uint amountOut,
        address[] calldata path,
        address to,
        uint deadline
    )
        external
        payable
        override
        ensure(deadline)
        returns (uint[] memory amounts)
    {
        require(path[0] == WETH, "UniswapV2Router: INVALID_PATH");
        amounts = UniswapV2Library.getAmountsIn(factory, amountOut, path);
        require(
            amounts[0] <= msg.value,
            "UniswapV2Router: EXCESSIVE_INPUT_AMOUNT"
        );
        IWETH(WETH).deposit{value: amounts[0]}();
        assert(
            IWETH(WETH).transfer(
                UniswapV2Library.pairFor(factory, path[0], path[1]),
                amounts[0]
            )
        );
        _swap(amounts, path, to);
        //区别于之前的方法，因为是先转账，这个方法还需将未使用完的ETH返回给msg.sender
        if (msg.value > amounts[0])
            TransferHelper.safeTransferETH(msg.sender, msg.value - amounts[0]); // refund dust eth, if any
    }

    function quote(
        uint amountA,
        uint reserveA,
        uint reserveB
    ) public pure override returns (uint amountB) {
        return UniswapV2Library.quote(amountA, reserveA, reserveB);
    }

    function getAmountOut(
        uint amountIn,
        uint reserveIn,
        uint reserveOut
    ) public pure override returns (uint amountOut) {
        return UniswapV2Library.getAmountOut(amountIn, reserveIn, reserveOut);
    }

    function getAmountIn(
        uint amountOut,
        uint reserveIn,
        uint reserveOut
    ) public pure override returns (uint amountIn) {
        return UniswapV2Library.getAmountOut(amountOut, reserveIn, reserveOut);
    }

    function getAmountsOut(
        uint amountIn,
        address[] memory path
    ) public view override returns (uint[] memory amounts) {
        return UniswapV2Library.getAmountsOut(factory, amountIn, path);
    }

    function getAmountsIn(
        uint amountOut,
        address[] memory path
    ) public view override returns (uint[] memory amounts) {
        return UniswapV2Library.getAmountsIn(factory, amountOut, path);
    }
}
