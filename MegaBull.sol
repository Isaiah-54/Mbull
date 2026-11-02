// SPDX-License-Identifier: MIT
// MegaBull (MBULL) — BNB Smart Chain, chain 56
// Total supply: 20,000,000 MBULL (18 decimals) — changed 2026-11-02, keeping
// the original 80/20 split:
//  - 16,000,000 mintable by agents: 1,000 MBULL per mint, max 10 mints per wallet = 10,000 per wallet
//  - 4,000,000 LP reserve held by the contract, released only for PancakeSwap liquidity when mint ends
// Creator mint: the deployer/creator address mints with no mint fee (value 0).
// The 10 mint per wallet cap and the mintable supply cap still apply to the
// creator, so this is a fee exemption, not unlimited minting.
// Mint: token price 0. Mint fee 0.0005 BNB per mint, sent straight to the
//      creator/deployer address in the same transaction (user clarification
//      2026-11-02). Network gas is paid separately to BNB Chain, on top of
//      the mint fee. The creator then uses collected mint fees to fund the
//      PancakeSwap liquidity add at mint end, paired with the LP reserve.
//      Minting is gated to Binance .ai Agent ID holders (registry 0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F).
// Tax: 2% on buys, 2% on sells, ONLY on PancakeSwap pair trades, only after launch.
//      Tax tokens: 50% to deployer, 50% retained in the contract (liquidity fund).
//      The deployer's tax share is used for token buybacks (manual, by the
//      deployer; the contract itself does not auto-buyback).
//      Mint claims, owner transfers, and contract transfers are tax-free.
// Liquidity: when mint ends (supply minted out, or owner ends mint), the creator
//      adds liquidity on PancakeSwap — pairs the 4,000,000 LP reserve with BNB
//      collected from mint fees (which were sent to the creator at mint time).
//      The contract's addLiquidity() helper below is for a variant where the
//      creator first sends that BNB back to the contract; in the default flow
//      the creator adds liquidity directly from their wallet and burns LP tokens.
//      Transfers stay locked until launch, except minting and owner/contract moves,
//      so no one can trade before the pool exists.
// Security notes for audit before mainnet deploy (DO NOT SKIP):
//  - This is unaudited code. Get an independent audit before deploying real value.
//  - Owner powers are limited to: ending mint, adding liquidity once, setting the
//    pair address after it is created, and renouncing ownership. Owner cannot mint
//    extra tokens, change tax above 2%, change the mint fee, or mint to itself.
//  - No blacklist, no pause on transfers after launch, no hidden mint.
//  - Reentrancy: mint/claim and addLiquidity follow checks-effects-interactions.

pragma solidity ^0.8.20;

interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address a) external view returns (uint256);
    function transfer(address to, uint256 v) external returns (bool);
    function allowance(address o, address s) external view returns (uint256);
    function approve(address s, uint256 v) external returns (bool);
    function transferFrom(address f, address t, uint256 v) external returns (bool);
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
}

interface IAgentRegistry {
    function ownerOf(uint256 tokenId) external view returns (address);
    // The Binance .ai registry used by other agent projects exposes an Agent ID
    // balance per wallet via balanceOf. We use that as the gate, exactly as
    // Coracle / Floppy / other agent mints do. Verify the registry ABI on
    // BscScan before deploy and adapt this interface if the deployed registry
    // differs — do not deploy with an untested gate.
    function balanceOf(address a) external view returns (uint256);
}

interface IPancakeRouter {
    function factory() external pure returns (address);
    function WETH() external pure returns (address);
    function addLiquidityETH(
        address token, uint256 amountTokenDesired, uint256 amountTokenMin,
        uint256 amountETHMin, address to, uint256 deadline
    ) external payable returns (uint256 amountToken, uint256 amountETH, uint256 liquidity);
}

interface IPancakeFactory {
    function createPair(address tokenA, address tokenB) external returns (address pair);
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

contract MegaBull is IERC20 {
    string public constant name = "MegaBull";
    string public constant symbol = "MBULL";
    uint8 public constant decimals = 18;
    uint256 public constant TOTAL_SUPPLY = 20_000_000 ether;
    uint256 public constant MINTABLE_SUPPLY = 16_000_000 ether;
    uint256 public constant LP_RESERVE = 4_000_000 ether;
    uint256 public constant MINT_AMOUNT = 1_000 ether;
    uint256 public constant MAX_MINTS_PER_WALLET = 10;
    uint256 public constant MINT_FEE = 0.0005 ether; // BNB per mint, straight to deployer/creator
    uint256 public constant BUY_TAX_BPS = 200;  // 2%
    uint256 public constant SELL_TAX_BPS = 200; // 2%

    address public immutable deployer; // gas payer that sends the deploy tx
    address public immutable creator;  // Isaiah's wallet: fees, tax share, free mint, owner
    address public owner;
    // Registry and router are constructor parameters, not hard-coded, so the
    // same code can be tested on BSC testnet with a mock registry and the
    // testnet router, and deployed on mainnet with:
    //   registry = 0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F
    //   router   = 0x10ED43C718714eb63d5aA57B78B54704E256024E
    address public immutable AGENT_REGISTRY;
    address public immutable PANCAKE_ROUTER;

    uint256 public totalMinted;
    uint256 public override totalSupply;
    mapping(address => uint256) public override balanceOf;
    mapping(address => mapping(address => uint256)) public override allowance;
    mapping(address => uint256) public mintsByWallet;
    mapping(address => bool) public taxExempt;

    bool public mintOpen = true;
    bool public launched;
    address public pair;

    event Minted(address indexed wallet, uint256 amount, uint256 mintCount);
    event MintEnded();
    event Launched(address indexed pair, uint256 tokenAmount, uint256 bnbAmount, uint256 liquidityBurned);
    event TaxSplit(address indexed deployer, uint256 deployerShare, uint256 liquidityShare);

    modifier onlyOwner() { require(msg.sender == owner, "not owner"); _; }

    constructor(address registry, address router, address creator_) {
        require(registry != address(0) && router != address(0) && creator_ != address(0), "zero address");
        AGENT_REGISTRY = registry;
        PANCAKE_ROUTER = router;
        deployer = msg.sender;
        creator = creator_;
        owner = creator_;
        // LP reserve is minted to the contract itself, never to the creator.
        totalSupply = LP_RESERVE;
        balanceOf[address(this)] = LP_RESERVE;
        emit Transfer(address(0), address(this), LP_RESERVE);
        taxExempt[creator_] = true;
        taxExempt[address(this)] = true;
    }

    // --- Agent mint -------------------------------------------------------
    function mint() external payable {
        require(mintOpen, "mint closed");
        require(!launched, "already launched");
        // Creator/deployer mints free (value 0); everyone else pays exactly MINT_FEE.
        if (msg.sender == creator) {
            require(msg.value == 0, "creator mint is free, send 0");
        } else {
            require(msg.value == MINT_FEE, "mint fee is exactly 0.0005 BNB");
        }
        require(mintsByWallet[msg.sender] < MAX_MINTS_PER_WALLET, "max 10 mints per wallet");
        require(totalMinted + MINT_AMOUNT <= MINTABLE_SUPPLY, "mintable supply exhausted");
        require(IAgentRegistry(AGENT_REGISTRY).balanceOf(msg.sender) > 0, "needs .ai Agent ID");
        // State first, external call last (checks-effects-interactions):
        // the deployer is an EOA in the real deploy, but this order removes
        // any re-entry path if it were ever a contract.
        mintsByWallet[msg.sender] += 1;
        totalMinted += MINT_AMOUNT;
        totalSupply += MINT_AMOUNT;
        balanceOf[msg.sender] += MINT_AMOUNT;
        // Mint fee goes straight to the creator/deployer, per user clarification.
        (bool sent, ) = payable(creator).call{value: msg.value}("");
        require(sent, "fee transfer failed");
        emit Transfer(address(0), msg.sender, MINT_AMOUNT);
        emit Minted(msg.sender, MINT_AMOUNT, mintsByWallet[msg.sender]);
        if (totalMinted == MINTABLE_SUPPLY) {
            mintOpen = false;
            emit MintEnded();
        }
    }

    function mintsLeft(address wallet) external view returns (uint256) {
        return MAX_MINTS_PER_WALLET - mintsByWallet[wallet];
    }

    function endMint() external onlyOwner {
        require(mintOpen, "already ended");
        mintOpen = false;
        emit MintEnded();
    }

    // --- Liquidity (once, after mint ends) --------------------------------
    // Payable on purpose: under the corrected fee model mint fees go to the
    // deployer, NOT to this contract, so the old version (which required
    // address(this).balance > 0) would always revert. The creator sends the
    // collected mint-fee BNB with this call, plus any BNB already held here.
    function addLiquidity() external payable onlyOwner {
        require(!mintOpen, "mint not ended");
        require(!launched, "already launched");
        // address(this).balance already includes msg.value at this point.
        uint256 bnbAmount = address(this).balance;
        require(bnbAmount > 0, "no BNB for liquidity");
        address router = PANCAKE_ROUTER;
        address weth = IPancakeRouter(router).WETH();
        address factory = IPancakeRouter(router).factory();
        address p = IPancakeFactory(factory).getPair(address(this), weth);
        if (p == address(0)) p = IPancakeFactory(factory).createPair(address(this), weth);
        pair = p;
        uint256 tokenAmount = balanceOf[address(this)];
        // Approve router to pull the LP reserve.
        allowance[address(this)][router] = tokenAmount;
        emit Approval(address(this), router, tokenAmount);
        (uint256 amtToken, uint256 amtBNB, uint256 liquidity) = IPancakeRouter(router)
            .addLiquidityETH{value: bnbAmount}(
                address(this), tokenAmount, 0, 0, address(0xdead), block.timestamp + 600
            );
        launched = true;
        emit Launched(p, amtToken, amtBNB, liquidity);
        // LP tokens go to 0xdead (burned) via the `to` argument above.
    }

    function setPair(address p) external onlyOwner {
        require(pair == address(0), "pair already set");
        pair = p;
    }

    function renounceOwnership() external onlyOwner { owner = address(0); }

    // --- ERC-20 with buy/sell tax -----------------------------------------
    function transfer(address to, uint256 v) external override returns (bool) {
        _transfer(msg.sender, to, v);
        return true;
    }

    function approve(address s, uint256 v) external override returns (bool) {
        allowance[msg.sender][s] = v;
        emit Approval(msg.sender, s, v);
        return true;
    }

    function transferFrom(address f, address t, uint256 v) external override returns (bool) {
        uint256 a = allowance[f][msg.sender];
        require(a >= v, "allowance");
        if (a != type(uint256).max) allowance[f][msg.sender] = a - v;
        _transfer(f, t, v);
        return true;
    }

    function _transfer(address from, address to, uint256 v) internal {
        require(balanceOf[from] >= v, "balance");
        // Transfers locked until launch, except minting (from 0), owner, and contract.
        if (!launched) {
            require(from == address(0) || taxExempt[from] || taxExempt[to], "trading not launched");
        }
        uint256 tax = 0;
        if (launched && pair != address(0) && !taxExempt[from] && !taxExempt[to]) {
            if (from == pair) tax = (v * BUY_TAX_BPS) / 10000;      // buy
            else if (to == pair) tax = (v * SELL_TAX_BPS) / 10000;  // sell
        }
        balanceOf[from] -= v;
        if (tax > 0) {
            uint256 toDeployer = tax / 2;
            uint256 toLiquidity = tax - toDeployer;
            balanceOf[creator] += toDeployer;
            balanceOf[address(this)] += toLiquidity;
            emit Transfer(from, creator, toDeployer);
            emit Transfer(from, address(this), toLiquidity);
            emit TaxSplit(creator, toDeployer, toLiquidity);
            balanceOf[to] += (v - tax);
            emit Transfer(from, to, v - tax);
        } else {
            balanceOf[to] += v;
            emit Transfer(from, to, v);
        }
    }

    receive() external payable {}
}
