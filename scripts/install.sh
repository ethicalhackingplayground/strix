#!/usr/bin/env bash

set -euo pipefail

APP=strix
REPO="ethicalhackingplayground/strix"
STRIX_IMAGE="ghcr.io/usestrix/strix-sandbox:0.1.13"
LOCAL_IMAGE="strix-sandbox:local"

MUTED='\033[0;2m'
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

requested_version=${VERSION:-}
SKIP_DOWNLOAD=false

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

INSTALL_DIR=$HOME/.strix/bin
mkdir -p "$INSTALL_DIR"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

usage() {
    cat <<EOF
🦅 Strix Installation Script

Usage: $(basename "$0") [OPTIONS]

Options:
    -h, --help              Show this help message
    -l, --local             Build from local source, install, build Docker, push to registry
    -p, --push             Just build Docker image and push to local registry (skip CLI build)
    -v, --version VERSION  Specific version to install

Examples:
    $(basename "$0")                      # Install latest from GitHub
    $(basename "$0") --local               # Build CLI from source + Docker + push
    $(basename "$0") --push                # Just build Docker and push (skip CLI build)

EOF
}

USE_LOCAL=false
PUSH_ONLY=false

while [[ $# -gt 0 ]]; do
    case $1 in
        -l|--local)
            USE_LOCAL=true
            shift
            ;;
        -p|--push)
            PUSH_ONLY=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            shift
            ;;
    esac
done

if [ "$USE_LOCAL" = false ]; then
    if [ -z "$requested_version" ]; then
        specific_version=$(curl -s "https://api.github.com/repos/$REPO/releases/latest" | sed -n 's/.*"tag_name": *"v\([^"]*\)".*/\1/p')
        if [[ $? -ne 0 || -z "$specific_version" ]]; then
            echo -e "${RED}Failed to fetch version information${NC}"
            exit 1
        fi
    else
        specific_version=$requested_version
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

check_existing_installation() {
    local found_paths=()
    while IFS= read -r -d '' path; do
        found_paths+=("$path")
    done < <(which -a strix 2>/dev/null | tr '\n' '\0' || true)

    if [ ${#found_paths[@]} -gt 0 ]; then
        for path in "${found_paths[@]}"; do
            if [[ ! -e "$path" ]] || [[ "$path" == "$INSTALL_DIR/strix"* ]]; then
                continue
            fi

            if [[ -n "$path" ]]; then
                echo -e "${MUTED}Found existing strix at: ${NC}$path"

                if [[ "$path" == *".local/bin"* ]]; then
                    echo -e "${MUTED}Removing old pipx installation...${NC}"
                    if command -v pipx >/dev/null 2>&1; then
                        pipx uninstall strix-agent 2>/dev/null || true
                    fi
                    rm -f "$path" 2>/dev/null || true
                elif [[ -L "$path" || -f "$path" ]]; then
                    echo -e "${MUTED}Removing old installation...${NC}"
                    rm -f "$path" 2>/dev/null || true
                fi
            fi
        done
    fi
}

check_version() {
    check_existing_installation

    if [[ -x "$INSTALL_DIR/strix" ]]; then
        installed_version=$("$INSTALL_DIR/strix" --version 2>/dev/null | awk '{print $2}' || echo "")
        if [[ "$installed_version" == "$specific_version" ]]; then
            print_message info "${GREEN}✓ Strix ${NC}$specific_version${GREEN} already installed${NC}"
            SKIP_DOWNLOAD=true
        elif [[ -n "$installed_version" ]]; then
            print_message info "${MUTED}Installed: ${NC}$installed_version ${MUTED}→ Upgrading to ${NC}$specific_version"
        fi
    fi
}

build_from_local() {
    print_message info "${CYAN}🔨 Building Strix from local source${NC}"
    print_message info "${MUTED}Project root: ${NC}$PROJECT_ROOT"

    local build_dir="$PROJECT_ROOT/dist"
    mkdir -p "$build_dir"

    cd "$PROJECT_ROOT"

    if [ -f "pyproject.toml" ] || [ -f "setup.py" ]; then
        print_message info "${MUTED}Building Python binary with PyInstaller...${NC}"
        if command -v uv >/dev/null 2>&1; then
            uv run pyinstaller strix.spec --noconfirm --distpath "$build_dir" --workpath "$build_dir/.build"
        elif command -v pyinstaller >/dev/null 2>&1; then
            pyinstaller strix.spec --noconfirm --distpath "$build_dir" --workpath "$build_dir/.build"
        else
            print_message error "${RED}pyinstaller not found. Install with: pip install pyinstaller${NC}"
            exit 1
        fi
    elif [ -f "go.mod" ]; then
        print_message info "${MUTED}Building Go binary...${NC}"
        CGO_ENABLED=0 GOOS=$os GOARCH=$arch go build -ldflags="-s -w" -o "$build_dir/strix-$target" cmd/strix/main.go
    elif [ -f "Cargo.toml" ]; then
        print_message info "${MUTED}Building Rust binary...${NC}"
        cargo build --release --locked 2>/dev/null || cargo build --release
        local binary_path=""
        if [ -f "target/release/strix" ]; then
            binary_path="target/release/strix"
        elif [ -f "target/release/$APP" ]; then
            binary_path="target/release/$APP"
        fi
        if [[ -n "$binary_path" ]]; then
            cp "$binary_path" "$build_dir/strix-$target"
        fi
    elif [ -f "package.json" ]; then
        print_message info "${MUTED}Building Node.js binary...${NC}"
        npm run build 2>/dev/null || true
        if [ -f "dist/index.js" ]; then
            cp "dist/index.js" "$build_dir/strix-$target"
        fi
    else
        print_message error "${RED}No build system found in project root${NC}"
        exit 1
    fi

    if [ -f "$build_dir/strix-$target" ]; then
        print_message success "${GREEN}✓ Built strix-$target${NC}"
    elif [ -f "$build_dir/strix" ]; then
        print_message success "${GREEN}✓ Built strix${NC}"
    else
        print_message error "${RED}Build failed${NC}"
        exit 1
    fi
}

download_and_install() {
    print_message info "\n${CYAN}🦅 Installing Strix${NC} ${MUTED}version: ${NC}$specific_version"
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

start_local_registry() {
    print_message info "${CYAN}🚀 Starting local Docker registry${NC}"

    local registry_name="strix-registry"
    local registry_port="5000"

    if docker ps -a --format '{{.Names}}' | grep -q "^${registry_name}$"; then
        if docker ps --format '{{.Names}}' | grep -q "^${registry_name}$"; then
            print_message info "${MUTED}Registry already running${NC}"
            return 0
        else
            print_message info "${MUTED}Starting existing registry...${NC}"
            docker start "$registry_name"
            return 0
        fi
    fi

    print_message info "${MUTED}Starting registry on port ${registry_port}${NC}"
    docker run -d \
        --name "$registry_name" \
        --restart=always \
        -p $registry_port:5000 \
        -v registry-data:/var/lib/registry \
        registry:2

    print_message success "${GREEN}✓ Local registry running on localhost:5000${NC}"
}

build_and_push_docker() {
    print_message info "${CYAN}🐳 Building and pushing Docker image${NC}"
    print_message info "${MUTED}Project root: ${NC}$PROJECT_ROOT"

    start_local_registry

    cd "$PROJECT_ROOT"

    local dockerfile="containers/Dockerfile"
    if [ ! -f "$dockerfile" ]; then
        dockerfile="Dockerfile"
    fi

    if [ ! -f "$dockerfile" ]; then
        print_message error "${RED}No Dockerfile found${NC}"
        exit 1
    fi

    print_message info "${MUTED}Building image: ${LOCAL_IMAGE}${NC}"
    docker build \
        --build-arg BUILDKIT_INLINE_CACHE=1 \
        -t "$LOCAL_IMAGE" \
        -f "$dockerfile" \
        . || { echo -e "${RED}Docker build failed${NC}"; exit 1; }

    print_message success "${GREEN}✓ Built: ${LOCAL_IMAGE}${NC}"

    local registry="localhost:5000"
    local remote_tag="${registry}/${LOCAL_IMAGE}"

    print_message info "${MUTED}Tagging: ${remote_tag}${NC}"
    docker tag "$LOCAL_IMAGE" "$remote_tag"

    print_message info "${MUTED}Pushing to ${registry}${NC}"
    docker push "$remote_tag" || { echo -e "${RED}Push failed${NC}"; exit 1; }

    print_message success "${GREEN}✓ Pushed: ${remote_tag}${NC}"
    print_message info "${MUTED}To run:${NC}"
    echo -e "  ${CYAN}docker run -p 8080:8080 ${remote_tag}${NC}"
    echo -e "  ${CYAN}STRIX_IMAGE=${remote_tag} strix --target https://example.com${NC}"
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
        print_message info "${MUTED}PATH already configured in ${NC}$config_file"
    elif [[ -w $config_file ]]; then
        echo -e "\n# strix" >> "$config_file"
        echo "$command" >> "$config_file"
        print_message info "${MUTED}Successfully added ${NC}strix ${MUTED}to \$PATH in ${NC}$config_file"
    else
        print_message warning "Manually add the directory to $config_file (or similar):"
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
            config_files="${ZDOTDIR:-$HOME}/.zshrc ${ZDOTDIR:-$HOME}/.zshenv $XDG_CONFIG_HOME/zsh/.zshrc $XDG_CONFIG_HOME/zsh/.zshenv"
            ;;
        bash)
            config_files="$HOME/.bashrc $HOME/.bash_profile $HOME/.profile $XDG_CONFIG_HOME/bash/.bashrc $XDG_CONFIG_HOME/bash/.bash_profile"
            ;;
        *)
            config_files="$HOME/.bashrc $HOME/.bash_profile"
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
        print_message warning "No config file found for $current_shell. You may need to manually add to PATH:"
        print_message info "  export PATH=$INSTALL_DIR:\$PATH"
    elif [[ ":$PATH:" != *":$INSTALL_DIR:"* ]]; then
        add_to_path "$config_file" "export PATH=$INSTALL_DIR:\$PATH"
    fi

    if [ -n "${GITHUB_ACTIONS-}" ] && [ "${GITHUB_ACTIONS}" == "true" ]; then
        echo "$INSTALL_DIR" >> "$GITHUB_PATH"
        print_message info "Added $INSTALL_DIR to \$GITHUB_PATH"
    fi
}

verify_installation() {
    export PATH="$INSTALL_DIR:$PATH"

    local which_strix=$(which strix 2>/dev/null || echo "")

    if [[ "$which_strix" != "$INSTALL_DIR/strix" && "$which_strix" != "$INSTALL_DIR/strix.exe" ]]; then
        if [[ -n "$which_strix" ]]; then
            echo -e "${YELLOW}⚠ Found conflicting strix at: ${NC}$which_strix"
            if rm -f "$which_strix" 2>/dev/null; then
                echo -e "${GREEN}✓ Removed conflicting installation${NC}"
            fi
        fi
    fi

    if [[ -x "$INSTALL_DIR/strix" ]]; then
        local version=$("$INSTALL_DIR/strix" --version 2>/dev/null | awk '{print $2}' || echo "unknown")
        echo -e "${GREEN}✓ Strix ${NC}$version${GREEN} ready${NC}"
    fi
}

if [ "$PUSH_ONLY" = true ]; then
    build_and_push_docker
elif [ "$USE_LOCAL" = true ]; then
    build_from_local

    BUILD_DIR="$PROJECT_ROOT/dist"
    if [ "$os" = "windows" ]; then
        cp "$BUILD_DIR/strix-$target.exe" "$INSTALL_DIR/strix.exe" 2>/dev/null || cp "$BUILD_DIR/strix.exe" "$INSTALL_DIR/strix.exe"
    else
        cp "$BUILD_DIR/strix-$target" "$INSTALL_DIR/strix" 2>/dev/null || cp "$BUILD_DIR/strix" "$INSTALL_DIR/strix"
        chmod 755 "$INSTALL_DIR/strix"
    fi
    print_message success "${GREEN}✓ Strix installed from local build${NC}"

    build_and_push_docker
else
    check_version
    if [ "$SKIP_DOWNLOAD" = false ]; then
        download_and_install
    fi
    setup_path
    verify_installation
    check_docker
fi

echo ""
echo -e "${CYAN}"
echo "   ███████╗████████╗██████╗ ██╗██╗  ██╗"
echo "   ██╔════╝╚══██╔══╝██╔══██╗██║╚██╗██╔╝"
echo "   ███████╗   ██║   ██████╔╝██║ ╚███╔╝ "
echo "   ╚════██║   ██║   ██╔══██╗██║ ██╔██╗ "
echo "   ███████║   ██║   ██║  ██║██║██╔╝ ██╗"
echo "   ╚══════╝   ╚═╝   ╚═╝  ╚═╝╚═╝╚═╝  ╚═╝"
echo -e "${NC}"
echo -e "${MUTED}  AI Penetration Testing Agent${NC}"
echo ""
echo -e "${MUTED}To get started:${NC}"
echo ""
echo -e "  ${CYAN}1.${NC} Set your environment:"
echo -e "     ${MUTED}export LLM_API_KEY='your-api-key'${NC}"
echo -e "     ${MUTED}export STRIX_LLM='openai/gpt-5.4'${NC}"
echo ""
echo -e "  ${CYAN}2.${NC} Run a penetration test:"
echo -e "     ${MUTED}strix --target https://example.com${NC}"
echo ""

echo -e "${YELLOW}→${NC} Run ${MUTED}source ~/.$(basename $SHELL)rc${NC} or open a new terminal"
echo ""
