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
    echo " Checking Ubuntu version..."
    CURRENT_VERSION=$(lsb_release -sr)
    echo "Current Ubuntu version: $CURRENT_VERSION"
    if [[ "$CURRENT_VERSION" != "24.04" ]]; then
        echo " Preparing to upgrade Ubuntu to 24.04 LTS..."
        sudo dpkg --configure -a
        sudo apt install -f -y
        sudo apt autoremove -y
        sudo apt autoclean
        sudo apt purge -y python3-distutils python3-lib2to3 python3-apt python3-update-manager ubuntu-release-upgrader-core update-manager-core ubuntu-advantage-tools 2>/dev/null || true
        sudo rm -rf /etc/apt/sources.list.d/* 2>/dev/null || true
        sudo sed -i '/packages.microsoft.com/d' /etc/apt/sources.list 2>/dev/null || true
        sudo sed -i '/repo.anaconda.com/d' /etc/apt/sources.list 2>/dev/null || true
        sudo sed -i '/dl.yarnpkg.com/d' /etc/apt/sources.list 2>/dev/null || true
        sudo sed -i '/packagecloud.io\/github\/git-lfs/d' /etc/apt/sources.list 2>/dev/null || true
        sudo rm -rf /var/lib/apt/lists/*
        sudo rm -f /var/lib/dpkg/lock-frontend /var/cache/apt/archives/lock
        sudo dpkg --configure -a
        sudo bash -c 'cat > /etc/apt/sources.list << EOL
deb http://archive.ubuntu.com/ubuntu noble main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu noble-updates main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu noble-backports main restricted universe multiverse
deb http://security.ubuntu.com/ubuntu noble-security main restricted universe multiverse
EOL'
        sudo apt clean
        for attempt in {1..3}; do
            if sudo apt update --fix-missing; then
                break
            else
                sleep 2
                if [ "$attempt" -eq 3 ]; then
                    exit 1
                fi
            fi
        done
        sudo apt install -f -y
        sudo mkdir -p /run/dbus
        sudo dbus-daemon --system --fork || true
        sudo debconf-set-selections <<< "postfix postfix/mailname string localhost"
        sudo debconf-set-selections <<< "postfix postfix/main_mailer_type string 'No configuration'"
        export DEBIAN_FRONTEND=noninteractive
        sudo apt install -y -o Dpkg::Options::="--force-confnew" python3 python3-apt
        sudo apt install -y -o Dpkg::Options::="--force-confnew" python3-update-manager ubuntu-release-upgrader-core
        sudo apt install -y -o Dpkg::Options::="--force-confnew" update-manager-core dbus
        sudo apt dist-upgrade -y
        sudo mkdir -p /etc/update-manager
        sudo bash -c 'cat > /etc/update-manager/release-upgrades << EOL
[DEFAULT]
Prompt=lts
EOL'
        sudo DEBIAN_FRONTEND=noninteractive do-release-upgrade -f DistUpgradeViewNonInteractive --allow-third-party || sudo apt full-upgrade -y
        sudo apt update && sudo apt upgrade -y
        sudo apt full-upgrade -y
        NEW_VERSION=$(lsb_release -sr)
        echo "New Ubuntu version: $NEW_VERSION"
        if [[ "$NEW_VERSION" != "24.04" ]]; then
            exit 1
        fi
        GLIBC_VERSION=$(ldd --version | head -n1 | awk '{print $NF}')
        if [[ "$GLIBC_VERSION" < "2.39" ]]; then
            exit 1
        fi
    else
        GLIBC_VERSION=$(ldd --version | head -n1 | awk '{print $NF}')
        if [[ "$GLIBC_VERSION" < "2.39" ]]; then
            sudo apt-get install --reinstall -y libc6
            sudo ldconfig
        fi
    fi
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
        export PATH="$HOME/.foundry/bin:$PATH"
        foundryup
    fi

    if ! command -v bun &> /dev/null; then
        echo "Installing Bun..."
        curl -fsSL https://bun.sh/install | bash
        export PATH="$HOME/.bun/bin:$PATH"
        echo 'export PATH="$HOME/.bun/bin:$PATH"' >> ~/.bashrc
    fi

    if ! command -v vlayer &> /dev/null; then
        echo "Installing vLayer CLI..."
        curl -SL https://install.vlayer.xyz/ | bash
        export PATH="$HOME/.vlayerup/bin:$HOME/.vlayer/bin:$PATH"
        echo 'export PATH="$HOME/.vlayerup/bin:$HOME/.vlayer/bin:$PATH"' >> ~/.bashrc
        source ~/.bashrc
        vlayerup
    fi
}

setup_env() {
    echo " Setting up environment file..."
    mkdir -p ~/Vlayer
    CHAIN_NAME=$DEFAULT_CHAIN_NAME
    JSON_RPC_URL=$DEFAULT_JSON_RPC_URL
    VLAYER_API_TOKEN=""
    EXAMPLES_TEST_PRIVATE_KEY=""

    if [ -f "$ENV_FILE" ]; then
        set -a
        source "$ENV_FILE"
        set +a
    else
        read -p "Enter your vLayer API token: " VLAYER_API_TOKEN
        read -p "Enter your test private key (e.g., 0x...): " EXAMPLES_TEST_PRIVATE_KEY

        cat > "$ENV_FILE" << EOL
VLAYER_API_TOKEN=$VLAYER_API_TOKEN
EXAMPLES_TEST_PRIVATE_KEY=$EXAMPLES_TEST_PRIVATE_KEY
CHAIN_NAME=$CHAIN_NAME
JSON_RPC_URL=$JSON_RPC_URL
EOL
        chmod 600 "$ENV_FILE"
        echo ".env" >> ~/Vlayer/.gitignore
    fi

    if [ -z "$VLAYER_API_TOKEN" ] || [ -z "$EXAMPLES_TEST_PRIVATE_KEY" ] || [ -z "$CHAIN_NAME" ] || [ -z "$JSON_RPC_URL" ]; then
        echo "Missing required variables."
        exit 1
    fi
}

setup_repo() {
    echo " Setting up repository..."
    if [ -d "$HOME/Vlayer/.git" ]; then
        cd ~/Vlayer && git pull origin main || true
    else
        rm -rf ~/Vlayer
        git clone https://github.com/Gmhax/Vlayer.git ~/Vlayer
        cd ~/Vlayer
    fi
}

setup_project() {
    local project_dir=$1
    local template=$2
    local project_name=$3

    echo " Setting up $project_name..."
    mkdir -p "$project_dir"
    cd "$project_dir"

    export PATH="$HOME/.vlayerup/bin:$HOME/.vlayer/bin:$PATH"

    if [ ! -f "foundry.toml" ]; then
        vlayer init --template "$template"
    fi

    forge build
    cd vlayer
    bun install

    cat > .env.mainnet.local << EOL
VLAYER_API_TOKEN=$VLAYER_API_TOKEN
EXAMPLES_TEST_PRIVATE_KEY=$EXAMPLES_TEST_PRIVATE_KEY
CHAIN_NAME=$CHAIN_NAME
JSON_RPC_URL=$JSON_RPC_URL
EOL

    echo "Running prove:mainnet for $project_name..."
    if bun run | grep -q "prove:mainnet"; then
        bun run prove:mainnet || echo "Warning: prove:mainnet failed"
    else
        echo "Warning: No prove:mainnet script defined in package.json"
    fi

    cd ~/Vlayer
}

main() {
    PROJECT_TYPE="${1:-}"
    if [ -z "$PROJECT_TYPE" ]; then
        read -p "Enter project type to set up [default: all]: " PROJECT_TYPE
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
    echo " All done! vLayer setup complete for $PROJECT_TYPE."
}

main "$@"
