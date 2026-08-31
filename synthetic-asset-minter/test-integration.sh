#!/bin/bash
# =============================================================================
# Integration Test Script for Synthetic Asset Minter
# Tests the full mint/burn flow with live CRE feeds
# Auto-refreshes price feed if stale
# =============================================================================
set -e

GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
DEPLOYED_ADDRESSES="$ROOT_DIR/deployed-addresses.json"
CRE_CONFIG="$ROOT_DIR/sample-cre-pricefeeds-por/aws-oracle-cre/api-oracle/config.staging.json"
CRE_DIR="$ROOT_DIR/sample-cre-pricefeeds-por/aws-oracle-cre"

# Load addresses from deployed-addresses.json or config.staging.json
load_addresses() {
    if [ -f "$DEPLOYED_ADDRESSES" ]; then
        SYNTHETIC_MINTER=$(jq -r '.contracts.SyntheticMinter' "$DEPLOYED_ADDRESSES")
        SYNTHETIC_TOKEN=$(jq -r '.contracts.SyntheticToken' "$DEPLOYED_ADDRESSES")
        PRICE_FEED=$(jq -r '.contracts.PriceFeed' "$DEPLOYED_ADDRESSES")
        USDC=$(jq -r '.contracts.USDC' "$DEPLOYED_ADDRESSES")
    elif [ -f "$CRE_CONFIG" ]; then
        SYNTHETIC_MINTER=$(jq -r '.evms[0].syntheticMinterAddress' "$CRE_CONFIG")
        SYNTHETIC_TOKEN=$(jq -r '.evms[0].syntheticTokenAddress' "$CRE_CONFIG")
        PRICE_FEED=$(jq -r '.evms[0].priceFeedAddress' "$CRE_CONFIG")
        USDC="${USDC_ADDRESS:-0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238}"
    else
        echo -e "${RED}Error: No deployed contract addresses found.${NC}" >&2
        echo "Expected one of:" >&2
        echo "  - $DEPLOYED_ADDRESSES" >&2
        echo "  - $CRE_CONFIG" >&2
        echo "" >&2
        echo "Deploy the contracts first with ./deploy-e2e.sh, then re-run this test." >&2
        exit 1
    fi

    # Guard against partially-populated / zero-address config
    for pair in "SyntheticMinter:$SYNTHETIC_MINTER" "SyntheticToken:$SYNTHETIC_TOKEN" "PriceFeed:$PRICE_FEED" "USDC:$USDC"; do
        name="${pair%%:*}"
        addr="${pair#*:}"
        if [ -z "$addr" ] || [ "$addr" = "null" ] || [ "$addr" = "0x0000000000000000000000000000000000000000" ]; then
            echo -e "${RED}Error: $name address is missing or zero. Redeploy with ./deploy-e2e.sh.${NC}" >&2
            exit 1
        fi
    done
}

RPC_URL="${RPC_URL:-https://ethereum-sepolia-rpc.publicnode.com}"

# Check prerequisites and load private key
if [ -z "$PRIVATE_KEY" ]; then
    CRE_ENV="$CRE_DIR/.env"
    if [ -f "$CRE_ENV" ]; then
        source "$CRE_ENV"
        if [ -n "$CRE_ETH_PRIVATE_KEY" ]; then
            export PRIVATE_KEY="0x$CRE_ETH_PRIVATE_KEY"
        fi
    fi
fi

if [ -z "$PRIVATE_KEY" ]; then
    echo -e "${RED}Error: PRIVATE_KEY not set${NC}"
    echo "Export PRIVATE_KEY or add CRE_ETH_PRIVATE_KEY to aws-oracle-cre/.env"
    exit 1
fi

load_addresses
DEPLOYER=$(cast wallet address --private-key $PRIVATE_KEY)

parse_uint() { echo "$1" | awk '{print $1}'; }

# =============================================================================
# Helper: Run CRE workflow to refresh price feed
# =============================================================================
refresh_price_feed() {
    echo -e "${YELLOW}Running CRE workflow to refresh price feed...${NC}"
    
    if ! command -v cre &>/dev/null; then
        echo -e "${RED}ERROR: CRE CLI not installed${NC}"
        return 1
    fi
    
    if ! cre whoami &>/dev/null; then
        echo -e "${RED}ERROR: CRE not authenticated. Run 'cre login' first.${NC}"
        return 1
    fi
    
    # Load CRE env
    if [ -f "$CRE_DIR/.env" ]; then
        set -a
        source "$CRE_DIR/.env"
        set +a
    fi
    
    # Run CRE workflow with broadcast
    local current_dir=$(pwd)
    cd "$CRE_DIR"
    cre workflow simulate ./api-oracle --broadcast --target staging-settings
    local result=$?
    cd "$current_dir"
    
    if [ $result -eq 0 ]; then
        echo -e "${GREEN}✅ Price feed refreshed${NC}"
        sleep 3
        return 0
    else
        echo -e "${RED}ERROR: CRE workflow failed${NC}"
        return 1
    fi
}

# =============================================================================
# Main Test Flow
# =============================================================================
echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}           Synthetic Asset Minter Integration Test             ${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo ""
echo "Deployer:        $DEPLOYER"
echo "SyntheticMinter: $SYNTHETIC_MINTER"
echo "SyntheticToken:  $SYNTHETIC_TOKEN"
echo "PriceFeed:       $PRICE_FEED"
echo ""

# =============================================================================
# Step 1: Check CRE Feeds (auto-refresh if stale)
# =============================================================================
echo -e "${BLUE}--- Step 1: Check CRE Feeds ---${NC}"
PRICE_DATA=$(cast call $PRICE_FEED "getLatestPrice()(uint256,uint256)" --rpc-url $RPC_URL)
PRICE=$(parse_uint "$(echo "$PRICE_DATA" | head -1)")
PRICE_TS=$(parse_uint "$(echo "$PRICE_DATA" | tail -1)")

STALENESS=$(parse_uint "$(cast call $SYNTHETIC_MINTER 'stalenessWindow()(uint256)' --rpc-url $RPC_URL)")
NOW=$(date +%s)
AGE=$((NOW - PRICE_TS))

# Check if feed needs refresh
NEEDS_REFRESH=false
if [ "$PRICE" = "0" ] || [ "$PRICE_TS" = "0" ]; then
    echo -e "${YELLOW}Price feed not populated${NC}"
    NEEDS_REFRESH=true
elif [ $AGE -gt $STALENESS ]; then
    PRICE_USD=$(echo "scale=2; $PRICE / 100000000" | bc)
    echo "Price: \$$PRICE_USD, Age: ${AGE}s (stale - window: ${STALENESS}s)"
    NEEDS_REFRESH=true
fi

# Auto-refresh if stale
if [ "$NEEDS_REFRESH" = "true" ]; then
    echo -e "${YELLOW}⚠️  Price feed is stale, attempting auto-refresh...${NC}"
    if refresh_price_feed; then
        PRICE_DATA=$(cast call $PRICE_FEED "getLatestPrice()(uint256,uint256)" --rpc-url $RPC_URL)
        PRICE=$(parse_uint "$(echo "$PRICE_DATA" | head -1)")
        PRICE_TS=$(parse_uint "$(echo "$PRICE_DATA" | tail -1)")
        NOW=$(date +%s)
        AGE=$((NOW - PRICE_TS))
    else
        echo -e "${RED}ERROR: Could not refresh price feed${NC}"
        exit 1
    fi
fi

PRICE_USD=$(echo "scale=2; $PRICE / 100000000" | bc)
echo "Price: \$$PRICE_USD, Age: ${AGE}s, Staleness Window: ${STALENESS}s"

if [ $AGE -gt $STALENESS ]; then
    echo -e "${RED}ERROR: Price feed still stale after refresh${NC}"
    exit 1
fi
echo -e "${GREEN}✅ Feed is fresh${NC}"

# =============================================================================
# Step 2: Check Current Position
# =============================================================================
echo ""
echo -e "${BLUE}--- Step 2: Check Current Position ---${NC}"
TOTAL_COL=$(parse_uint "$(cast call $SYNTHETIC_MINTER 'totalCollateral(address)(uint256)' $DEPLOYER --rpc-url $RPC_URL)")
LOCKED_COL=$(parse_uint "$(cast call $SYNTHETIC_MINTER 'lockedCollateral(address)(uint256)' $DEPLOYER --rpc-url $RPC_URL)")
SYN_BAL=$(parse_uint "$(cast call $SYNTHETIC_TOKEN 'balanceOf(address)(uint256)' $DEPLOYER --rpc-url $RPC_URL)")
USDC_BAL=$(parse_uint "$(cast call $USDC 'balanceOf(address)(uint256)' $DEPLOYER --rpc-url $RPC_URL)")

echo "Total Collateral: $(echo "scale=6; $TOTAL_COL / 1000000" | bc) USDC"
echo "Locked Collateral: $(echo "scale=6; $LOCKED_COL / 1000000" | bc) USDC"
echo "sSPY Balance: $(echo "scale=6; $SYN_BAL / 1000000000000000000" | bc)"
echo "USDC Balance: $(echo "scale=6; $USDC_BAL / 1000000" | bc)"

# =============================================================================
# Step 3: Deposit Collateral (if needed)
# =============================================================================
echo ""
echo -e "${BLUE}--- Step 3: Deposit Collateral ---${NC}"
if [ "$TOTAL_COL" = "0" ]; then
    if [ "$USDC_BAL" = "0" ]; then
        echo -e "${YELLOW}No USDC balance. Get testnet USDC from https://faucet.circle.com/${NC}"
        exit 1
    fi
    
    DEP_AMT=$((USDC_BAL / 2))
    echo "Depositing $(echo "scale=6; $DEP_AMT / 1000000" | bc) USDC..."
    
    cast send $USDC "approve(address,uint256)" $SYNTHETIC_MINTER $DEP_AMT \
        --rpc-url $RPC_URL --private-key $PRIVATE_KEY --json > /dev/null
    
    DEP_TX=$(cast send $SYNTHETIC_MINTER "depositCollateral(uint256)" $DEP_AMT \
        --rpc-url $RPC_URL --private-key $PRIVATE_KEY --json | jq -r '.transactionHash')
    
    echo -e "${GREEN}✅ Deposited (tx: ${DEP_TX:0:10}...)${NC}"
    TOTAL_COL=$(parse_uint "$(cast call $SYNTHETIC_MINTER 'totalCollateral(address)(uint256)' $DEPLOYER --rpc-url $RPC_URL)")
else
    echo -e "${GREEN}✅ Collateral already deposited: $(echo "scale=6; $TOTAL_COL / 1000000" | bc) USDC${NC}"
fi

# =============================================================================
# Step 4: Mint Synthetic Tokens
# =============================================================================
echo ""
echo -e "${BLUE}--- Step 4: Mint Synthetic Tokens ---${NC}"
MAX_MINT=$(parse_uint "$(cast call $SYNTHETIC_MINTER 'getMaxMintable(address)(uint256)' $DEPLOYER --rpc-url $RPC_URL)")

if [ "$MAX_MINT" = "0" ]; then
    echo -e "${YELLOW}No available collateral to mint${NC}"
else
    MINT_AMT=$((MAX_MINT / 2))
    echo "Minting $(echo "scale=6; $MINT_AMT / 1000000000000000000" | bc) sSPY..."
    
    MINT_TX=$(cast send $SYNTHETIC_MINTER "mint(uint256)" $MINT_AMT \
        --rpc-url $RPC_URL --private-key $PRIVATE_KEY --json | jq -r '.transactionHash')
    
    echo -e "${GREEN}✅ Minted (tx: ${MINT_TX:0:10}...)${NC}"
    
    CR=$(parse_uint "$(cast call $SYNTHETIC_MINTER 'getUserCollateralRatio(address)(uint256)' $DEPLOYER --rpc-url $RPC_URL)")
    echo "Collateralization Ratio: ${CR}%"
fi

# =============================================================================
# Step 5: Burn Synthetic Tokens
# =============================================================================
echo ""
echo -e "${BLUE}--- Step 5: Burn Synthetic Tokens ---${NC}"
SYN_BAL=$(parse_uint "$(cast call $SYNTHETIC_TOKEN 'balanceOf(address)(uint256)' $DEPLOYER --rpc-url $RPC_URL)")

if [ "$SYN_BAL" = "0" ]; then
    echo -e "${YELLOW}No tokens to burn${NC}"
else
    BURN_AMT=$((SYN_BAL / 2))
    LOCKED_BEFORE=$(parse_uint "$(cast call $SYNTHETIC_MINTER 'lockedCollateral(address)(uint256)' $DEPLOYER --rpc-url $RPC_URL)")
    
    echo "Burning $(echo "scale=6; $BURN_AMT / 1000000000000000000" | bc) sSPY..."
    
    BURN_TX=$(cast send $SYNTHETIC_MINTER "burn(uint256)" $BURN_AMT \
        --rpc-url $RPC_URL --private-key $PRIVATE_KEY --json | jq -r '.transactionHash')
    
    LOCKED_AFTER=$(parse_uint "$(cast call $SYNTHETIC_MINTER 'lockedCollateral(address)(uint256)' $DEPLOYER --rpc-url $RPC_URL)")
    RELEASED=$((LOCKED_BEFORE - LOCKED_AFTER))
    
    echo -e "${GREEN}✅ Burned, released $(echo "scale=6; $RELEASED / 1000000" | bc) USDC (tx: ${BURN_TX:0:10}...)${NC}"
fi

# =============================================================================
# Final State
# =============================================================================
echo ""
echo -e "${BLUE}--- Final State ---${NC}"
F_TOTAL=$(parse_uint "$(cast call $SYNTHETIC_MINTER 'totalCollateral(address)(uint256)' $DEPLOYER --rpc-url $RPC_URL)")
F_LOCKED=$(parse_uint "$(cast call $SYNTHETIC_MINTER 'lockedCollateral(address)(uint256)' $DEPLOYER --rpc-url $RPC_URL)")
F_SYN=$(parse_uint "$(cast call $SYNTHETIC_TOKEN 'balanceOf(address)(uint256)' $DEPLOYER --rpc-url $RPC_URL)")
F_USDC=$(parse_uint "$(cast call $USDC 'balanceOf(address)(uint256)' $DEPLOYER --rpc-url $RPC_URL)")

echo "Total Collateral: $(echo "scale=6; $F_TOTAL / 1000000" | bc) USDC"
echo "Locked Collateral: $(echo "scale=6; $F_LOCKED / 1000000" | bc) USDC"
echo "Available: $(echo "scale=6; ($F_TOTAL - $F_LOCKED) / 1000000" | bc) USDC"
echo "sSPY Balance: $(echo "scale=6; $F_SYN / 1000000000000000000" | bc)"
echo "USDC Balance: $(echo "scale=6; $F_USDC / 1000000" | bc)"

if [ "$F_SYN" != "0" ]; then
    CR=$(parse_uint "$(cast call $SYNTHETIC_MINTER 'getUserCollateralRatio(address)(uint256)' $DEPLOYER --rpc-url $RPC_URL)")
    echo "Collateralization Ratio: ${CR}%"
fi

echo ""
echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}                    ALL TESTS PASSED                           ${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
