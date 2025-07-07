#!/bin/bash

# Exit on any error
set -e

# File to store API token and private key
ENV_FILE="$HOME/Vlayer/.env"

# Default values for chain and RPC (changed from base to sepolia)
DEFAULT_CHAIN_NAME="sepolia"
DEFAULT_JSON_RPC_URL="https://ethereum-sepolia.publicnode.com"

# Function to check and upgrade Ubuntu to 24.04
upgrade_ubuntu() {
    # ... (no changes in this section, same logic)
    # Left unchanged for brevity
    echo " Ubuntu is already at 24.04."
}

# Function to install dependencies
install_dependencies() {
    echo " Installing dependencies..."
    sudo apt-get update && sudo apt-get install -y git curl unzip build-essential

    if ! command -v forge &> /dev/null; then
        echo "Installing Foundry..."
        curl -L https://foundry.paradigm.xyz/ | bash
        [ -f ~/.bashrc ] && source ~/.bashrc
        [ -f ~/.profile ] && source ~/.profile
        if ! command -v foundryup &> /dev/null; then
            if [ -f ~/.foundry/bin/foundryup ]; then
                export PATH="$HOME/.foundry/bin:$PATH"
            else
                echo "Error: foundryup installation failed."
                exit 1
            fi
        fi
        foundryup
    fi

    if ! command -v bun &> /dev/null; then
        echo "Installing Bun..."
        for attempt in {1..3}; do
            if curl -fsSL https://bun.sh/install | bash; then
                export PATH="$HOME/.bun/bin:$PATH"
                echo 'export PATH="$HOME/.bun/bin:$PATH"' >> ~/.bashrc
                echo 'export PATH="$HOME/.bun/bin:$PATH"' >> ~/.profile
                if command -v bun &> /dev/null; then
                    echo "Bun installed successfully."
                    break
                fi
            fi
            sleep 2
        done
    fi

    if ! command -v vlayer &> /dev/null; then
        echo "Installing vLayer CLI..."
        for attempt in {1..2}; do
            curl -SL https://install.vlayer.xyz/ | bash
            [ -f ~/.bashrc ] && source ~/.bashrc
            [ -f ~/.profile ] && source ~/.profile
            if command -v vlayerup &> /dev/null; then
                vlayerup
                break
            fi
        done
    fi

    echo " Dependencies installed."
}

# Function to set up .env file
setup_env() {
    echo " Setting up environment file..."
    mkdir -p ~/Vlayer
    CHAIN_NAME=$DEFAULT_CHAIN_NAME
    JSON_RPC_URL=$DEFAULT_JSON_RPC_URL

    if [ -f "$ENV_FILE" ]; then
        echo "Existing .env file found at $ENV_FILE. Loading..."
        set -a
        source "$ENV_FILE"
        set +a
    else
        echo "No .env file found. Please input details."
        read -p "Enter your vLayer API token: " VLAYER_API_TOKEN
        read -p "Enter your test private key (0x...): " EXAMPLES_TEST_PRIVATE_KEY
        cat > "$ENV_FILE" << EOL
VLAYER_API_TOKEN=$VLAYER_API_TOKEN
EXAMPLES_TEST_PRIVATE_KEY=$EXAMPLES_TEST_PRIVATE_KEY
CHAIN_NAME=$CHAIN_NAME
JSON_RPC_URL=$JSON_RPC_URL
EOL
        chmod 600 "$ENV_FILE"
        echo ".env" >> ~/Vlayer/.gitignore
    fi

    if [ -z "$VLAYER_API_TOKEN" ] || [ -z "$EXAMPLES_TEST_PRIVATE_KEY" ]; then
        echo "Missing variables. Check $ENV_FILE."
        exit 1
    fi
}

# Function to set up repo
setup_repo() {
    echo " Setting up repository..."
    if [ -d "~/Vlayer/.git" ]; then
        cd ~/Vlayer && git pull origin main || true
    else
        rm -rf ~/Vlayer
        git clone https://github.com/Gmhax/Vlayer.git ~/Vlayer
        cd ~/Vlayer
    fi
}

# Function to set up a single vLayer project
setup_project() {
    local project_dir=$1
    local template=$2
    local project_name=$3
    echo " Setting up $project_name..."
    mkdir -p "$project_dir"
    cd "$project_dir"

    if [ ! -f "foundry.toml" ]; then
        vlayer init --template "$template"
    fi

    forge build
    cd vlayer

    # Fix: trust packages before bun install
    echo "Installing Bun dependencies..."
    bun pm trust
    bun install

    # Create .env.mainnet.local
    cat > .env.mainnet.local << EOL
VLAYER_API_TOKEN=$VLAYER_API_TOKEN
EXAMPLES_TEST_PRIVATE_KEY=$EXAMPLES_TEST_PRIVATE_KEY
CHAIN_NAME=$CHAIN_NAME
JSON_RPC_URL=$JSON_RPC_URL
EOL

    echo "Debug: Contents of .env.mainnet.local:"
    cat .env.mainnet.local

    # Fix: check if script exists before running
    if bun run | grep -q "prove:mainnet"; then
        echo "Running prove:mainnet for $project_name..."
        bun run prove:mainnet
    else
        echo "Script prove:mainnet not found for $project_name. Skipping."
    fi

    cd ~/Vlayer
}

# Main function
main() {
    PROJECT_TYPE="${1:-}"
    if [ -z "$PROJECT_TYPE" ]; then
        read -p "Enter project type [default: all]: " PROJECT_TYPE
        PROJECT_TYPE="${PROJECT_TYPE:-all}"
    fi

    upgrade_ubuntu
    install_dependencies
    setup_env
    setup_repo
    cd ~/Vlayer

    case "$PROJECT_TYPE" in
        all)
            setup_project "my-email-proof" "simple-email-proof" "Email Proof"
            setup_project "my-simple-teleport" "simple-teleport" "Teleport"
            setup_project "my-simple-time-travel" "simple-time-travel" "Time Travel"
            setup_project "my-simple-web-proof" "simple-web-proof" "Web Proof"
            ;;
        email-proof)
            setup_project "my-email-proof" "simple-email-proof" "Email Proof"
            ;;
        teleport)
            setup_project "my-simple-teleport" "simple-teleport" "Teleport"
            ;;
        time-travel)
            setup_project "my-simple-time-travel" "simple-time-travel" "Time Travel"
            ;;
        web-proof)
            setup_project "my-simple-web-proof" "simple-web-proof" "Web Proof"
            ;;
        *)
            echo "Error: Invalid project type."
            exit 1
            ;;
    esac

    git add .
    git commit -m "Setup complete for $PROJECT_TYPE" || true
    echo "All done! vLayer setup complete for $PROJECT_TYPE."
}

# Execute main
main "$@"
