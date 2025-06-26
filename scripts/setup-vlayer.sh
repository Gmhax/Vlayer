#!/bin/bash

# Exit on any error
set -e

# File to store API token and private key
ENV_FILE="$HOME/Vlayer/.env"

# Default values for chain and RPC
DEFAULT_CHAIN_NAME="base"
DEFAULT_JSON_RPC_URL="https://base-rpc.publicnode.com"

# Function to check and upgrade Ubuntu to 24.04
upgrade_ubuntu() {
    echo "🔍 Checking Ubuntu version..."
    CURRENT_VERSION=$(lsb_release -sr)
    echo "Current Ubuntu version: $CURRENT_VERSION"
    if [[ "$CURRENT_VERSION" != "24.04" ]]; then
        echo "🚀 Preparing to upgrade Ubuntu to 24.04 LTS..."
        # Fix broken packages
        echo "Fixing broken packages..."
        sudo dpkg --configure -a
        sudo apt install -f -y
        sudo apt autoremove -y
        sudo apt autoclean
        # Purge conflicting Python and upgrade tools
        echo "Purging conflicting Python and upgrade tools..."
        sudo apt purge -y python3-distutils python3-lib2to3 python3-apt python3-update-manager ubuntu-release-upgrader-core update-manager-core ubuntu-advantage-tools 2>/dev/null || true
        # Clean up all third-party repositories
        echo "Removing all third-party repositories..."
        sudo rm -rf /etc/apt/sources.list.d/* 2>/dev/null || true
        sudo sed -i '/packages.microsoft.com/d' /etc/apt/sources.list 2>/dev/null || true
        sudo sed -i '/repo.anaconda.com/d' /etc/apt/sources.list 2>/dev/null || true
        sudo sed -i '/dl.yarnpkg.com/d' /etc/apt/sources.list 2>/dev/null || true
        sudo sed -i '/packagecloud.io\/github\/git-lfs/d' /etc/apt/sources.list 2>/dev/null || true
        # Clear APT caches and locks
        echo "Clearing APT caches and locks..."
        sudo rm -rf /var/lib/apt/lists/*
        sudo rm -f /var/lib/dpkg/lock-frontend /var/cache/apt/archives/lock
        sudo dpkg --configure -a
        # Set up clean Ubuntu noble repositories
        echo "Setting up Ubuntu 24.04 (noble) repositories..."
        sudo bash -c 'cat > /etc/apt/sources.list << EOL
deb http://archive.Ubuntu.com/ubuntu noble main restricted universe multiverse
deb http://archive.Ubuntu.com/ubuntu noble-updates main restricted universe multiverse
deb http://archive.Ubuntu.com/ubuntu noble-backports main restricted universe multiverse
deb http://security.Ubuntu.com/ubuntu noble-security main restricted universe multiverse
EOL'
        # Update package lists
        echo "Updating package lists..."
        sudo apt clean
        for attempt in {1..3}; do
            if sudo apt update --fix-missing; then
                break
            else
                echo "Warning: apt update failed, retrying ($attempt/3)..."
                sleep 2
                if [ "$attempt" -eq 3 ]; then
                    echo "Error: Failed to update package lists after retries."
                    exit 1
                fi
            fi
        done
        sudo apt install -f -y
        # Start DBus to fix system bus issues
        echo "Starting DBus service..."
        sudo mkdir -p /run/dbus
        sudo dbus-daemon --system --fork || true
        # Preconfigure Postfix to avoid prompts
        echo "Preconfiguring Postfix to 'No configuration'..."
        sudo debconf-set-selections <<< "postfix postfix/mailname string localhost"
        sudo debconf-set-selections <<< "postfix postfix/main_mailer_type string 'No configuration'"
        # Install Python and upgrade dependencies for 24.04 with noninteractive frontend
        echo "Installing Python and upgrade dependencies..."
        export DEBIAN_FRONTEND=noninteractive
        sudo apt install -y -o Dpkg::Options::="--force-confnew" python3 python3-apt
        sudo apt install -y -o Dpkg::Options::="--force-confnew" python3-update-manager ubuntu-release-upgrader-core
        sudo apt install -y -o Dpkg::Options::="--force-confnew" update-manager-core
        sudo apt install -y -o Dpkg::Options::="--force-confnew" dbus
        sudo apt dist-upgrade -y
        # Configure for LTS upgrades with proper section headers
        echo "Configuring system for LTS upgrades..."
        sudo mkdir -p /etc/update-manager
        sudo bash -c 'cat > /etc/update-manager/release-upgrades << EOL
[DEFAULT]
Prompt=lts
EOL'
        # Attempt upgrade
        echo "Running LTS upgrade to 24.04..."
        sudo DEBIAN_FRONTEND=noninteractive do-release-upgrade -f DistUpgradeViewNonInteractive --allow-third-party || {
            echo "do-release-upgrade failed, forcing noble upgrade..."
            sudo apt full-upgrade -y
        }
        sudo apt update && sudo apt upgrade -y
        sudo apt full-upgrade -y
        # Verify upgrade
        NEW_VERSION=$(lsb_release -sr)
        echo "New Ubuntu version: $NEW_VERSION"
        if [[ "$NEW_VERSION" != "24.04" ]]; then
            echo "Error: Failed to upgrade to Ubuntu 24.04 (current version: $NEW_VERSION)."
            echo "Please check /var/log/dist-upgrade for details or manually run:"
            echo "  sudo do-release-upgrade -f DistUpgradeViewNonInteractive"
            exit 1
        fi
        # Verify glibc
        GLIBC_VERSION=$(ldd --version | head -n1 | awk '{print $NF}')
        echo "Detected glibc version after upgrade: $GLIBC_VERSION"
        if [[ "$GLIBC_VERSION" < "2.39" ]]; then
            echo "Error: glibc version ($GLIBC_VERSION) is too old after upgrade. Expected 2.39."
            exit 1
        fi
        echo "✅ Ubuntu upgraded to $NEW_VERSION with glibc $GLIBC_VERSION."
    else
        echo "✅ Ubuntu is already at 24.04."
        GLIBC_VERSION=$(ldd --version | head -n1 | awk '{print $NF}')
        echo "Detected glibc version: $GLIBC_VERSION"
        if [[ "$GLIBC_VERSION" < "2.39" ]]; then
            echo "⚠️ glibc version too old, reinstalling libc6..."
            sudo apt-get install --reinstall -y libc6
            sudo ldconfig
            GLIBC_VERSION=$(ldd --version | head -n1 | awk '{print $NF}')
            echo "New glibc version: $GLIBC_VERSION"
            if [[ "$GLIBC_VERSION" < "2.39" ]]; then
                echo "Error: glibc still too old ($GLIBC_VERSION)."
                exit 1
            fi
        fi
    fi
}

# Function to install dependencies
install_dependencies() {
    echo "🔧 Installing dependencies..."

    # Core system deps
    sudo apt-get update && sudo apt-get install -y git curl unzip build-essential

    # Install Foundry
    if ! command -v forge &> /dev/null; then
        echo "Installing Foundry..."
        curl -L https://foundry.paradigm.xyz/ | bash
        # Ensure PATH is updated
        [ -f ~/.bashrc ] && source ~/.bashrc
        [ -f ~/.profile ] && source ~/.profile
        # Verify foundryup
        if ! command -v foundryup &> /dev/null; then
            echo "⚠️ foundryup not found in PATH. Trying to locate it..."
            if [ -f ~/.foundry/bin/foundryup ]; then
                export PATH="$HOME/.foundry/bin:$PATH"
            else
                echo "Error: foundryup installation failed. Please run 'curl -L https://foundry.paradigm.xyz/ | bash' manually, then 'foundryup'."
                exit 1
            fi
        fi
        foundryup
    else
        echo "Foundry already installed."
    fi

    # Install Bun with retries and explicit PATH update
    if ! command -v bun &> /dev/null; then
        echo "Installing Bun..."
        for attempt in {1..3}; do
            if curl -fsSL https://bun.sh/install | bash; then
                # Explicitly add Bun to PATH
                export PATH="$HOME/.bun/bin:$PATH"
                # Update .bashrc for future sessions
                echo 'export PATH="$HOME/.bun/bin:$PATH"' >> ~/.bashrc
                # Verify installation
                if command -v bun &> /dev/null; then
                    echo "Bun installed successfully."
                    break
                else
                    echo "⚠️ Bun not found after install, retrying ($attempt/3)..."
                    sleep 2
                fi
            else
                echo "⚠️ Bun install failed, retrying ($attempt/3)..."
                sleep 2
            fi
            if [ "$attempt" -eq 3 ]; then
                echo "Error: Bun installation failed after retries. Please install manually:"
                echo "  curl -fsSL https://bun.sh/install | bash"
                echo "  export PATH=\"\$HOME/.bun/bin:\$PATH\""
                echo "Then verify with: bun --version"
                exit 1
            fi
        done
    else
        echo "Bun already installed."
    fi

    # Verify Bun
    if ! command -v bun &> /dev/null; then
        echo "⚠️ Bun still not found in PATH. Trying to locate it..."
        if [ -f ~/.bun/bin/bun ]; then
            export PATH="$HOME/.bun/bin:$PATH"
            echo 'export PATH="$HOME/.bun/bin:$PATH"' >> ~/.bashrc
        else
            echo "Error: Bun not found after installation. Please install manually:"
            echo "  curl -fsSL https://bun.sh/install | bash"
            echo "  export PATH=\"\$HOME/.bun/bin:\$PATH\""
            echo "Then verify with: bun --version"
            exit 1
        fi
    fi
    echo "Bun version: $(bun --version)"

    # Install vLayer CLI
    if ! command -v vlayer &> /dev/null; then
        echo "Installing vLayer CLI..."
        for attempt in {1..2}; do
            curl -SL https://install.vlayer.xyz/ | bash
            # Ensure PATH is updated
            [ -f ~/.bashrc ] && source ~/.bashrc
            [ -f ~/.profile ] && source ~/.profile
            # Debug PATH and search for vlayerup
            echo "Debug: Current PATH: $PATH"
            echo "Debug: Searching for vlayerup..."
            VLAYERUP_PATH=$(find ~ -name vlayerup -type f 2>/dev/null | head -n 1)
            if [ -n "$VLAYERUP_PATH" ]; then
                echo "Debug: Found vlayerup at $VLAYERUP_PATH"
                chmod +x "$VLAYERUP_PATH"
                VLAYERUP_DIR=$(dirname "$VLAYERUP_PATH")
                export PATH="$VLAYERUP_DIR:$PATH"
            else
                echo "Debug: vlayerup not found via find."
            fi
            # Run vlayerup with retries
            for sub_attempt in {1..3}; do
                if command -v vlayerup &> /dev/null; then
                    echo "Running vlayerup to install vlayer (attempt $sub_attempt)..."
                    vlayerup
                    [ -f ~/.bashrc ] && source ~/.bashrc
                    [ -f ~/.profile ] && source ~/.profile
                    break
                else
                    echo "⚠️ vlayerup not found, retrying after delay (attempt $sub_attempt)..."
                    sleep 2
                fi
            done
            # Verify vlayer
            if command -v vlayer &> /dev/null; then
                if vlayer --version >/dev/null 2>&1; then
                    echo "vLayer CLI installed successfully."
                    break
                else
                    echo "⚠️ vlayer installed but failed to run (possible glibc issue). Reinstalling libc6..."
                    sudo apt-get install --reinstall -y libc6
                    sudo ldconfig
                    continue
                fi
            else
                echo "⚠️ vlayer not found in PATH. Trying to locate it..."
                for path in ~/.vlayer/bin ~/.vlayerup/bin ~/.local/bin ~/.bin /usr/local/bin; do
                    if [ -f "$path/vlayer" ]; then
                        export PATH="$path:$PATH"
                        echo "Found vlayer in $path, added to PATH."
                        break
                    fi
                done
                if command -v vlayer &> /dev/null && vlayer --version >/dev/null 2>&1; then
                    echo "vLayer CLI installed successfully."
                    break
                fi
            fi
            if [ "$attempt" -eq 2 ]; then
                echo "Error: vLayer CLI installation failed after retries. Please run manually:"
                echo "  curl -SL https://install.vlayer.xyz/ | bash"
                echo "  source ~/.bashrc"
                echo "  vlayerup"
                echo "Then verify with: vlayer --version"
                exit 1
            fi
        done
    else
        echo "vLayer CLI already installed."
        if ! vlayer --version >/dev/null 2>&1; then
            echo "⚠️ vlayer installed but not working (possible glibc issue). Reinstalling libc6..."
            sudo apt-get install --reinstall -y libc6
            sudo ldconfig
            if ! vlayer --version >/dev/null 2>&1; then
                echo "Error: vLayer CLI still not working. Please run manually:"
                echo "  sudo apt-get install --reinstall -y libc6"
                echo "  sudo ldconfig"
                echo "  vlayer --version"
                exit 1
            fi
        fi
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
    VLAYER_API_TOKEN=""
    EXAMPLES_TEST_PRIVATE_KEY=""

    # Check if .env file exists
    if [ -f "$ENV_FILE" ]; then
        echo "Existing .env file found at $ENV_FILE. Loading..."
        # Debug: Show file contents
        echo "Debug: Contents of $ENV_FILE:"
        cat "$ENV_FILE"
        # Source the file to load variables
        set -a
        source "$ENV_FILE"
        set +a
        # Reassign to ensure they're set in the current session
        VLAYER_API_TOKEN=${VLAYER_API_TOKEN:-}
        EXAMPLES_TEST_PRIVATE_KEY=${EXAMPLES_TEST_PRIVATE_KEY:-}
        CHAIN_NAME=${CHAIN_NAME:-$DEFAULT_CHAIN_NAME}
        JSON_RPC_URL=${JSON_RPC_URL:-$DEFAULT_JSON_RPC_URL}
        echo "Loaded variables:"
        echo "VLAYER_API_TOKEN=${VLAYER_API_TOKEN:0:5}... (truncated for security)"
        echo "EXAMPLES_TEST_PRIVATE_KEY=${EXAMPLES_TEST_PRIVATE_KEY:0:5}... (truncated for security)"
        echo "CHAIN_NAME=$CHAIN_NAME"
        echo "JSON_RPC_URL=$JSON_RPC_URL"
    else
        echo "No .env file found at $ENV_FILE. Please provide the following details."
        read -p "Enter your vLayer API token: " VLAYER_API_TOKEN
        read -p "Enter your test private key (e.g., 0x...): " EXAMPLES_TEST_PRIVATE_KEY

        # Create .env file
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

    # Verify required variables are set
    if [ -z "$VLAYER_API_TOKEN" ] || [ -z "$EXAMPLES_TEST_PRIVATE_KEY" ] || [ -z "$CHAIN_NAME" ] || [ -z "$JSON_RPC_URL" ]; then
        echo "Error: One or more required variables (VLAYER_API_TOKEN, EXAMPLES_TEST_PRIVATE_KEY, CHAIN_NAME, JSON_RPC_URL) are not set."
        echo "Contents of $ENV_FILE:"
        cat "$ENV_FILE"
        echo "Please ensure your .env file is correct or delete it to re-prompt:"
        echo "  rm $ENV_FILE"
        echo "Then rerun the script."
        exit 1
    fi
}

# Function to clone or update repo
setup_repo() {
    echo "📂 Setting up repository..."
    if [ -d "~/Vlayer/.git" ]; then
        echo "Repository already exists. Pulling latest changes..."
        cd ~/Vlayer
        git pull origin main || echo "No updates available or minor error, continuing..."
    else
        echo "Cloning repository..."
        rm -rf ~/Vlayer  # Clear any non-git directory
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

    # Validate variables before creating .env.testnet.local
    echo "Debug: Using VLAYER_API_TOKEN=${VLAYER_API_TOKEN:0:5}... (truncated for security)"
    echo "Debug: Using EXAMPLES_TEST_PRIVATE_KEY=${EXAMPLES_TEST_PRIVATE_KEY:0:5}... (truncated for security)"
    if [ -z "$VLAYER_API_TOKEN" ] || [ -z "$EXAMPLES_TEST_PRIVATE_KEY" ]; then
        echo "Error: VLAYER_API_TOKEN or EXAMPLES_TEST_PRIVATE_KEY is empty."
        echo "Please check $ENV_FILE or delete it to re-prompt:"
        echo "  rm $ENV_FILE"
        echo "Then rerun the script."
        exit 1
    fi

    # Create .env.testnet.local using the loaded variables (fixed typo)
    echo "Creating environment file for $project_name..."
    cat > .env.testnet.local << EOL
VLAYER_API_TOKEN=$VLAYER_API_TOKEN
EXAMPLES_TEST_PRIVATE_KEY=$EXAMPLES_TEST_PRIVATE_KEY
CHAIN_NAME=$CHAIN_NAME
JSON_RPC_URL=$JSON_RPC_URL
EOL

    # Verify .env.testnet.local
    echo "Debug: Contents of .env.testnet.local:"
    cat .env.testnet.local

    # Run prove:testnet
    echo "Running prove:testnet for $project_name..."
    bun run prove:testnet

    echo "✅ $project_name setup complete!"
    cd ~/Vlayer
}

# Main function to set up all projects
main() {
    # Accept project type as argument or prompt
    PROJECT_TYPE="${1:-}"
    if [ -z "$PROJECT_TYPE" ]; then
        echo "Available project types: all, email-proof, teleport, time-travel, web-proof"
        read -p "Enter project type to set up [default: all]: " PROJECT_TYPE
        PROJECT_TYPE="${PROJECT_TYPE:-all}"
    fi

    # Upgrade Ubuntu
    upgrade_ubuntu

    # Install dependencies
    install_dependencies

    # Set up .env (this should only prompt once)
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
