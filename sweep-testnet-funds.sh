#!/bin/bash

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to display usage
usage() {
    echo "Usage: $0 <target_wallet_name> <source_wallet1> [source_wallet2] ..."
    echo
    echo "Arguments:"
    echo "  target_wallet_name   - The wallet name to sweep all funds to"
    echo "  source_walletN       - Wallet names to sweep funds from"
    echo
    echo "Example:"
    echo "  $0 admin wallet1 wallet2 wallet3"
    echo
    echo "Note: Wallet names must be configured in your mantrachaind keyring"
    exit 1
}

# Check if at least 2 arguments are provided (target + at least one source)
if [ $# -lt 2 ]; then
    usage
fi

# Target wallet name (first argument)
TARGET_WALLET_NAME="$1"
shift

# Source wallet names (remaining arguments)
SOURCE_WALLETS=("$@")

# Network configuration - adjust as needed
CHAIN_ID="mantra-dukong-1"
RPC_NODE="https://rpc.dukong.mantrachain.io"
GAS_PRICES="0.01uom"
GAS_ADJUSTMENT="1.5"

# Function to get wallet address from wallet name
get_wallet_address() {
    local wallet_name=$1
    address=$(mantrachaind keys show "$wallet_name" --address 2>/dev/null)
    if [ -z "$address" ]; then
        echo ""
    else
        echo "$address"
    fi
}

# Get target wallet address
TARGET_WALLET=$(get_wallet_address "$TARGET_WALLET_NAME")
if [ -z "$TARGET_WALLET" ]; then
    echo -e "${RED}Error: Target wallet '$TARGET_WALLET_NAME' not found in keyring${NC}"
    exit 1
fi

# Validate source wallets exist
echo -e "${YELLOW}Validating wallets...${NC}"
VALID_WALLETS=()
for wallet_name in "${SOURCE_WALLETS[@]}"; do
    address=$(get_wallet_address "$wallet_name")
    if [ -z "$address" ]; then
        echo -e "${RED}Warning: Wallet '$wallet_name' not found in keyring - skipping${NC}"
    else
        VALID_WALLETS+=("$wallet_name")
        echo -e "${GREEN}✓${NC} Found wallet: $wallet_name ($address)"
    fi
done

if [ ${#VALID_WALLETS[@]} -eq 0 ]; then
    echo -e "${RED}Error: No valid source wallets found${NC}"
    exit 1
fi

echo
echo "========================================="
echo "MANTRA Testnet Funds Sweeper"
echo "Target: $TARGET_WALLET_NAME ($TARGET_WALLET)"
echo "Chain: $CHAIN_ID"
echo "Source wallets: ${#VALID_WALLETS[@]}"
echo "========================================="
echo

# Function to get balance
get_balance() {
    local address=$1
    balance=$(mantrachaind query bank balances $address --node $RPC_NODE --output json 2>/dev/null | jq -r '.balances[] | select(.denom=="uom") | .amount' || echo "0")
    if [ -z "$balance" ]; then
        echo "0"
    else
        echo "$balance"
    fi
}

# Function to convert uom to OM
format_balance() {
    local uom_amount=$1
    if [ "$uom_amount" -eq 0 ]; then
        echo "0 OM"
    else
        echo "scale=6; $uom_amount / 1000000" | bc | sed 's/^\./0./'
        echo -n " OM"
    fi
}

# Check balances first
echo -e "${YELLOW}Checking wallet balances...${NC}"
echo

total_to_sweep=0

for wallet_name in "${VALID_WALLETS[@]}"; do
    wallet_address=$(get_wallet_address "$wallet_name")
    balance=$(get_balance $wallet_address)
    formatted=$(format_balance $balance)

    if [ "$balance" -gt 0 ]; then
        echo -e "${GREEN}✓${NC} $wallet_name: $formatted (${balance}uom)"
        total_to_sweep=$((total_to_sweep + balance))
    else
        echo -e "${RED}✗${NC} $wallet_name: $formatted"
    fi
done

echo
echo -e "Total to sweep: ${YELLOW}$(format_balance $total_to_sweep)${NC}"
echo

# Ask for confirmation
read -p "Do you want to proceed with sweeping funds? (y/N): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
fi

echo
echo -e "${YELLOW}Starting sweep operation...${NC}"
echo

# Perform sweep
successful_sweeps=0
failed_sweeps=0

for wallet_name in "${VALID_WALLETS[@]}"; do
    wallet_address=$(get_wallet_address "$wallet_name")
    balance=$(get_balance $wallet_address)

    if [ "$balance" -le 0 ]; then
        echo -e "${YELLOW}Skipping${NC} $wallet_name (no balance)"
        continue
    fi

    # Reserve some for gas (100000uom = 0.1 OM)
    gas_reserve=100000
    if [ "$balance" -le "$gas_reserve" ]; then
        echo -e "${RED}Skipping${NC} $wallet_name (balance too low for gas)"
        continue
    fi

    amount_to_send=$((balance - gas_reserve))

    echo -e "Sweeping from ${GREEN}$wallet_name${NC}..."
    echo "  Amount: $(format_balance $amount_to_send)"

    # Execute the transfer
    tx_output=$(mantrachaind tx bank send \
        $wallet_name \
        $TARGET_WALLET_NAME \
        "${amount_to_send}uom" \
        --chain-id $CHAIN_ID \
        --node $RPC_NODE \
        --gas auto \
        --gas-adjustment $GAS_ADJUSTMENT \
        --gas-prices $GAS_PRICES \
        --yes \
        --output json 2>&1)

    # Check if transaction was successful
    if echo "$tx_output" | jq -e '.txhash' > /dev/null 2>&1; then
        txhash=$(echo "$tx_output" | jq -r '.txhash')
        echo -e "  ${GREEN}✓ Success${NC} - TxHash: $txhash"
        successful_sweeps=$((successful_sweeps + 1))

        # Wait a bit for the transaction to be processed
        sleep 2
    else
        echo -e "  ${RED}✗ Failed${NC}"
        echo "  Error: $tx_output"
        failed_sweeps=$((failed_sweeps + 1))
    fi
    echo
done

# Final summary
echo "========================================="
echo -e "${GREEN}Sweep Complete!${NC}"
echo "Successful: $successful_sweeps"
echo "Failed: $failed_sweeps"
echo

# Check final balance of target wallet
target_balance=$(get_balance $TARGET_WALLET)
echo -e "Target wallet final balance: ${GREEN}$(format_balance $target_balance)${NC}"
echo "========================================="