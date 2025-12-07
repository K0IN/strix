#!/usr/bin/env bash

set -euo pipefail

APP=strix
REPO="usestrix/strix"
STRIX_IMAGE="ghcr.io/usestrix/strix-sandbox:0.1.10"

MUTED='\033[0;2m'
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

requested_version=${VERSION:-}

raw_os=$(uname -s)
os=$(echo "$raw_os" | tr '[:upper:]' '[:lower:]')
case "$raw_os" in
  Darwin*) os="macos" ;;
  Linux*) os="linux" ;;
  MINGW*|MSYS*|CYGWIN*) os="windows" ;;
esac

arch=$(uname -m)
if [[ "$arch" == "aarch64" ]]; then
  arch="arm64"
fi
if [[ "$arch" == "x86_64" ]]; then
  arch="x86_64"
fi

if [ "$os" = "macos" ] && [ "$arch" = "x86_64" ]; then
  rosetta_flag=$(sysctl -n sysctl.proc_translated 2>/dev/null || echo 0)
  if [ "$rosetta_flag" = "1" ]; then
    arch="arm64"
  fi
fi

combo="$os-$arch"
case "$combo" in
  linux-x86_64|macos-x86_64|macos-arm64|windows-x86_64)
    ;;
  *)
    echo -e "${RED}Unsupported OS/Arch: $os/$arch${NC}"
    exit 1
    ;;
esac

archive_ext=".tar.gz"
if [ "$os" = "windows" ]; then
  archive_ext=".zip"
fi

target="$os-$arch"

if [ "$os" = "linux" ]; then
    if ! command -v tar >/dev/null 2>&1; then
         echo -e "${RED}Error: 'tar' is required but not installed.${NC}"
         exit 1
    fi
fi

if [ "$os" = "windows" ]; then
    if ! command -v unzip >/dev/null 2>&1; then
        echo -e "${RED}Error: 'unzip' is required but not installed.${NC}"
        exit 1
    fi
fi

INSTALL_DIR=$HOME/.strix/bin
mkdir -p "$INSTALL_DIR"

if [ -z "$requested_version" ]; then
    specific_version=$(curl -s "https://api.github.com/repos/$REPO/releases/latest" | sed -n 's/.*"tag_name": *"v\([^"]*\)".*/\1/p')
    if [[ $? -ne 0 || -z "$specific_version" ]]; then
        echo -e "${RED}Failed to fetch version information${NC}"
        exit 1
    fi
else
    specific_version=$requested_version
fi

filename="$APP-${specific_version}-${target}${archive_ext}"
url="https://github.com/$REPO/releases/download/v${specific_version}/$filename"

print_message() {
    local level=$1
    local message=$2
    local color=""
    case $level in
        info) color="${NC}" ;;
        success) color="${GREEN}" ;;
        warning) color="${YELLOW}" ;;
        error) color="${RED}" ;;
    esac
    echo -e "${color}${message}${NC}"
}

check_version() {
    if command -v strix >/dev/null 2>&1; then
        strix_path=$(which strix)
        installed_version=$(strix --version 2>/dev/null | awk '{print $2}' || echo "")

        if [[ -z "$installed_version" ]]; then
            print_message info "${MUTED}Found older strix at ${NC}$strix_path ${MUTED}(no version info)${NC}"
            print_message info "${MUTED}Upgrading to ${NC}$specific_version"
        elif [[ "$installed_version" == "$specific_version" ]]; then
            print_message info "${GREEN}✓ Strix ${NC}$specific_version${GREEN} already installed${NC}"
            check_docker
            exit 0
        else
            print_message info "${MUTED}Installed: ${NC}$installed_version ${MUTED}→ Upgrading to ${NC}$specific_version"
        fi
    fi
}

download_and_install() {
    print_message info "\n${CYAN}🦉 Installing Strix${NC} ${MUTED}version: ${NC}$specific_version"
    print_message info "${MUTED}Platform: ${NC}$target\n"

    local tmp_dir=$(mktemp -d)
    cd "$tmp_dir"

    echo -e "${MUTED}Downloading...${NC}"
    curl -# -L -o "$filename" "$url"

    if [ ! -f "$filename" ]; then
        echo -e "${RED}Download failed${NC}"
        exit 1
    fi

    echo -e "${MUTED}Extracting...${NC}"
    if [ "$os" = "windows" ]; then
        unzip -q "$filename"
        mv "strix-${specific_version}-${target}.exe" "$INSTALL_DIR/strix.exe"
    else
        tar -xzf "$filename"
        mv "strix-${specific_version}-${target}" "$INSTALL_DIR/strix"
        chmod 755 "$INSTALL_DIR/strix"
    fi

    cd - > /dev/null
    rm -rf "$tmp_dir"

    echo -e "${GREEN}✓ Strix installed to $INSTALL_DIR${NC}"
}

check_docker() {
    echo ""
    if ! command -v docker >/dev/null 2>&1; then
        echo -e "${YELLOW}⚠ Docker not found${NC}"
        echo -e "${MUTED}Strix requires Docker to run the security sandbox.${NC}"
        echo -e "${MUTED}Please install Docker: ${NC}https://docs.docker.com/get-docker/"
        echo ""
        return 1
    fi

    if ! docker info >/dev/null 2>&1; then
        echo -e "${YELLOW}⚠ Docker daemon not running${NC}"
        echo -e "${MUTED}Please start Docker and run: ${NC}docker pull $STRIX_IMAGE"
        echo ""
        return 1
    fi

    echo -e "${MUTED}Checking for sandbox image...${NC}"
    if docker image inspect "$STRIX_IMAGE" >/dev/null 2>&1; then
        echo -e "${GREEN}✓ Sandbox image already available${NC}"
    else
        echo -e "${MUTED}Pulling sandbox image (this may take a few minutes)...${NC}"
        if docker pull "$STRIX_IMAGE"; then
            echo -e "${GREEN}✓ Sandbox image pulled successfully${NC}"
        else
            echo -e "${YELLOW}⚠ Failed to pull sandbox image${NC}"
            echo -e "${MUTED}You can pull it manually later: ${NC}docker pull $STRIX_IMAGE"
        fi
    fi
    return 0
}

add_to_path() {
    local config_file=$1
    local command=$2
    if grep -Fxq "$command" "$config_file" 2>/dev/null; then
        return 0
    elif [[ -w $config_file ]]; then
        echo -e "\n# strix" >> "$config_file"
        echo "$command" >> "$config_file"
        print_message info "${MUTED}Added to PATH in ${NC}$config_file"
    else
        print_message warning "Manually add to $config_file:"
        print_message info "  $command"
    fi
}

setup_path() {
    XDG_CONFIG_HOME=${XDG_CONFIG_HOME:-$HOME/.config}
    current_shell=$(basename "$SHELL")

    case $current_shell in
        fish)
            config_files="$HOME/.config/fish/config.fish"
            ;;
        zsh)
            config_files="$HOME/.zshrc $HOME/.zshenv"
            ;;
        bash)
            config_files="$HOME/.bashrc $HOME/.bash_profile $HOME/.profile"
            ;;
        *)
            config_files="$HOME/.bashrc $HOME/.profile"
            ;;
    esac

    config_file=""
    for file in $config_files; do
        if [[ -f $file ]]; then
            config_file=$file
            break
        fi
    done

    if [[ -z $config_file ]]; then
        config_file="$HOME/.bashrc"
        touch "$config_file"
    fi

    if [[ ":$PATH:" != *":$INSTALL_DIR:"* ]]; then
        case $current_shell in
            fish)
                add_to_path "$config_file" "fish_add_path $INSTALL_DIR"
                ;;
            *)
                add_to_path "$config_file" "export PATH=\"$INSTALL_DIR:\$PATH\""
                ;;
        esac
    fi

    if [ -n "${GITHUB_ACTIONS-}" ] && [ "${GITHUB_ACTIONS}" == "true" ]; then
        echo "$INSTALL_DIR" >> "$GITHUB_PATH"
    fi
}

check_version
download_and_install
setup_path
check_docker

echo ""
echo -e "${CYAN}"
echo "   ███████╗████████╗██████╗ ██╗██╗  ██╗"
echo "   ██╔════╝╚══██╔══╝██╔══██╗██║╚██╗██╔╝"
echo "   ███████╗   ██║   ██████╔╝██║ ╚███╔╝ "
echo "   ╚════██║   ██║   ██╔══██╗██║ ██╔██╗ "
echo "   ███████║   ██║   ██║  ██║██║██╔╝ ██╗"
echo "   ╚══════╝   ╚═╝   ╚═╝  ╚═╝╚═╝╚═╝  ╚═╝"
echo -e "${NC}"
echo -e "${MUTED}  AI-Powered Penetration Testing Agent${NC}"
echo ""
echo -e "${MUTED}To get started:${NC}"
echo ""
echo -e "  ${CYAN}1.${NC} Set your LLM provider:"
echo -e "     ${MUTED}export STRIX_LLM='openai/gpt-4o'${NC}"
echo -e "     ${MUTED}export LLM_API_KEY='your-api-key'${NC}"
echo ""
echo -e "  ${CYAN}2.${NC} Run a scan:"
echo -e "     ${MUTED}strix --target https://example.com${NC}"
echo ""
echo -e "${MUTED}Website: ${NC}https://usestrix.com"
echo -e "${MUTED}Discord: ${NC}https://discord.gg/YjKFvEZSdZ"
echo ""

if [[ ":$PATH:" != *":$INSTALL_DIR:"* ]]; then
    echo -e "${YELLOW}⚠ Restart your shell or run:${NC}"
    echo -e "  source ~/.$(basename $SHELL)rc"
    echo ""
fi
