#!/bin/bash

# Exit on any error
set -e

# File to store API token and private key
ENV_FILE="$HOME/Vlayer/.env"

# Default values for chain and RPC
DEFAULT_CHAIN_NAME="optimismSepolia"
DEFAULT_JSON_RPC_URL="https://sepolia.optimism.io"

# Function to check and upgrade Ubuntu to 24.04
upgrade_ubuntu() {
    echo "🔍 Checking Ubuntu version..."
    CURRENT_VERSION=$(lsb_release -sr)
    if [[ "$CURRENT_VERSION" != "24.04" ]]; then
        echo "🚀 Preparing to upgrade Ubuntu to 24.04 LTS..."
        # Remove problematic git-lfs repository if present
        if ls /etc/apt/sources.list.d/*git-lfs* 2>/dev/null || grep -r "packagecloud.io/github/git-lfs" /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null; then
            echo "Removing problematic git-lfs repository..."
            sudo rm -f /etc/apt/sources.list.d/*git-lfs*
            sudo sed -i '/packagecloud.io\/github\/git-lfs/d' /etc/apt/sources.list
        fi
        # Clean APT cache and fix broken packages
        sudo apt clean
        sudo apt update --fix-missing || {
            echo "Warning: apt update had issues, retrying..."
            sudo apt update
        }
        sudo dpkg --configure -a
        sudo apt install -f -y
        sudo apt autoremove -y
        # Purge and reinstall critical packages to avoid aptsources/uaclient errors
        echo "Reinstalling python3-apt and ubuntu-advantage-tools..."
        sudo apt purge -y python3-apt ubuntu-advantage-tools || true
        sudo apt install -y python3-apt ubuntu-advantage-tools update-manager-core
        sudo apt dist-upgrade -y
        # Verify LTS upgrade configuration
        if ! grep -q "Prompt=lts" /etc/update-manager/release-upgrades; then
            echo "Configuring system for LTS upgrades..."
            sudo sed -i 's/Prompt=.*/Prompt=lts/' /etc/update-manager/release-upgrades || \
                echo "Prompt=lts" | sudo tee -a /etc/update-manager/release-upgrades
        fi
        # Perform the upgrade
        echo "Running LTS upgrade to 24.04..."
        sudo do-release-upgrade -f DistUpgradeViewNonInteractive
        sudo apt update && sudo apt upgrade -y
        sudo apt full-upgrade -y
        echo "✅ Ubuntu upgraded to $(lsb_release -sr). Rebooting..."
        sudo reboot
    else
        echo "✅ Ubuntu is already at 24.04."
    fi
}

# Function to install dependencies
install_dependencies() {
    echo "🔧 Installing dependencies..."

    # Core system deps
    sudo apt-get update && sudo apt-get install -y git curl unzip build-essential

    # Install Foundry
    if ! command -v forge &> /dev/null; then
        curl -L https://foundry.paradigm.xyz/ | bash
        source ~/.bashrc
        foundryup
    else
        echo "Foundry already installed."
    fi

    # Install Bun
    if ! command -v bun &> /dev/null; then
        curl -fsSL https://bun.sh/install | bash
        source ~/.profile
    else
        echo "Bun already installed."
    fi

    # Install vLayer CLI
    if ! command -v vlayer &> /dev/null; then
        curl -SL https://install.vlayer.xyz/ | bash
        source ~/.bashrc
        vlayerup
    else
        echo "vLayer CLI already installed."
    fi

    echo "✅ Dependencies installed."
}

# Function to set up .env file
setup_env() {
    echo "🔑 Setting up environment file..."
    mkdir -p ~/Vlayer

    # Initialize defaults
    CHAIN_NAME=$DEFAULT_CHAIN_NAME
    JSON_RPC_URL=$DEFAULT_JSON_RPC_URL

    if [ -f "$ENV_FILE" ]; then
        echo "Existing .env file found. Loading..."
        source "$ENV_FILE"
        # Ensure defaults if not set in .env
        CHAIN_NAME=${CHAIN_NAME:-$DEFAULT_CHAIN_NAME}
        JSON_RPC_URL=${JSON_RPC_URL:-$DEFAULT_JSON_RPC_URL}
    else
        echo "No .env file found. Please provide the following details."
        read -p "Enter your vLayer API token: " VLAYER_API_TOKEN
        read -p "Enter your test private key (e.g., 0x...): " EXAMPLES_TEST_PRIVATE_KEY

        # Create .env file with defaults
        cat > "$ENV_FILE" << EOL
VLAYER_API_TOKEN=$VLAYER_API_TOKEN
EXAMPLES_TEST_PRIVATE_KEY=$EXAMPLES_TEST_PRIVATE_KEY
CHAIN_NAME=$CHAIN_NAME
JSON_RPC_URL=$JSON_RPC_URL
EOL

        chmod 600 "$ENV_FILE"
        echo ".env" >> ~/Vlayer/.gitignore
        echo "✅ .env file created and secured at $ENV_FILE."
    fi

    # Verify required variables
    if [ -z "$VLAYER_API_TOKEN" ] || [ -z "$EXAMPLES_TEST_PRIVATE_KEY" ] || [ -z "$CHAIN_NAME" ] || [ -z "$JSON_RPC_URL" ]; then
        echo "Error: One or more required variables (VLAYER_API_TOKEN, EXAMPLES_TEST_PRIVATE_KEY, CHAIN_NAME, JSON_RPC_URL) are not set."
        echo "Please ensure your .env file or inputs are correct."
        exit 1
    fi
}

# Function to clone or update repo
setup_repo() {
    echo "📂 Setting up repository..."
    if [ -d "~/Vlayer" ]; then
        echo "Repository already exists. Pulling latest changes..."
        cd ~/Vlayer
        git pull origin main || echo "No updates available."
    else
        echo "Cloning repository..."
        git clone https://github.com/Gmhax/Vlayer.git ~/Vlayer
        cd ~/Vlayer
    fi
    echo "✅ Repository ready."
}

# Function to set up a single vLayer project
setup_project() {
    local project_dir=$1
    local template=$2
    local project_name=$3

    echo "🛠 Setting up $project_name..."
    mkdir -p "$project_dir"
    cd "$project_dir"

    # Initialize vLayer project
    if [ ! -f "foundry.toml" ]; then
        echo "Initializing vLayer project with template $template..."
        vlayer init --template "$template"
    else
        echo "vLayer project already initialized in $project_dir."
    fi

    # Build the project
    echo "Building project..."
    forge build

    # Navigate to vlayer directory
    cd vlayer

    # Install Bun dependencies
    echo "Installing Bun dependencies..."
    bun install

    # Create .env.testnet.local
    echo "Creating environment file for $project_name..."
    cat > .env.testnet.local << EOL
VLAYER_API_TOKEN=$VLAYER_API_TOKEN
EXAMPLES_TEST_PRIVATE_KEY=$EXAMPLES_TEST_PRIVATE_KEY
CHAIN_NAME=$CHAIN_NAME
JSON_RPC_URL=$JSON_RPC_URL
EOL

    # Run prove:testnet
    echo "Running prove:testnet for $project_name..."
    bun run prove:testnet

    echo "✅ $project_name setup complete!"
    cd ~/Vlayer
}

# Main function to set up all projects
main() {
    # Accept project type as argument or prompt
    PROJECT_TYPE=${1:-}
    if [ -z "$PROJECT_TYPE" ]; then
        echo "Available project types: all, email-proof, teleport, time-travel, web-proof"
        read -p "Enter project type to set up [default: all]: " PROJECT_TYPE
        PROJECT_TYPE=${PROJECT_TYPE:-all}
    fi

    # Upgrade Ubuntu
    upgrade_ubuntu

    # Install dependencies
    install_dependencies

    # Set up .env
    setup_env

    # Set up repo
    setup_repo

    # Change to repo directory
    cd ~/Vlayer

    # Set up projects based on input
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
            echo "Error: Invalid project type. Use: all, email-proof, teleport, time-travel, web-proof"
            exit 1
            ;;
    esac

    # Commit changes
    git add .
    git commit -m "Setup complete for $PROJECT_TYPE" || echo "No changes to commit."
    echo "🎉 All done! vLayer setup complete for $PROJECT_TYPE."
}

# Run main function with any passed argument
main "$@"
