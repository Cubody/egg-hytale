#!/bin/bash

ensure_downloader() {
    if [ ! -f "$DOWNLOADER" ]; then
        logger error "Hytale downloader not found!"
        logger error "Please run the installation script first."
        exit 1
    fi

    if [ ! -x "$DOWNLOADER" ]; then
        logger info "Setting executable permissions for downloader..."
        chmod +x "$DOWNLOADER"
    fi
}

extract_first_version() {
    grep -oE '[0-9]{4}\.[0-9]{2}\.[0-9]{2}-[a-fA-F0-9]+' | head -1
}

extract_downloader_latest_version() {
    sed -nE 's/.*available:[[:space:]]*([0-9]{4}\.[0-9]{2}\.[0-9]{2}-[a-fA-F0-9]+).*/\1/p' | head -1
}

extract_downloader_current_version() {
    sed -nE 's/.*\(current:[[:space:]]*([0-9]{4}\.[0-9]{2}\.[0-9]{2}-[a-fA-F0-9]+)\).*/\1/p' | head -1
}

version_build_id() {
    local VERSION="$1"

    if [[ "$VERSION" == *-* ]]; then
        printf '%s\n' "${VERSION##*-}"
    fi
}

server_versions_match() {
    local LOCAL_VERSION="$1"
    local REMOTE_VERSION="$2"

    if [ -z "$LOCAL_VERSION" ] || [ -z "$REMOTE_VERSION" ]; then
        return 1
    fi

    if [ "$LOCAL_VERSION" = "$REMOTE_VERSION" ]; then
        return 0
    fi

    local LOCAL_BUILD_ID=$(version_build_id "$LOCAL_VERSION")
    local REMOTE_BUILD_ID=$(version_build_id "$REMOTE_VERSION")

    # Hytale sometimes republishes the same server build with a new date prefix.
    # Treat identical build hashes as the same server to avoid re-downloading the full server.zip.
    if [ -n "$LOCAL_BUILD_ID" ] && [ "$LOCAL_BUILD_ID" = "$REMOTE_BUILD_ID" ]; then
        return 0
    fi

    return 1
}

install_downloader_update() {
    local LATEST_VERSION="$1"
    local CURRENT_VERSION="$2"
    local TMP_DIR
    local ZIP_PATH
    local EXTRACT_DIR
    local ARCH
    local SOURCE_BIN
    local TARGET_BIN
    local TARGET_NAME

    TMP_DIR=$(mktemp -d)
    if [ $? -ne 0 ] || [ -z "$TMP_DIR" ]; then
        logger warn "Failed to create a temporary directory for downloader update"
        return 1
    fi

    ZIP_PATH="$TMP_DIR/${DOWNLOAD_FILE:-hytale-downloader.zip}"
    EXTRACT_DIR="$TMP_DIR/extracted"
    mkdir -p "$EXTRACT_DIR"

    logger info "Downloading latest Hytale downloader${LATEST_VERSION:+ ($LATEST_VERSION)}..."
    if ! curl -fsSL -o "$ZIP_PATH" "$DOWNLOAD_URL"; then
        logger warn "Failed to download latest Hytale downloader"
        rm -rf "$TMP_DIR"
        return 1
    fi

    if ! unzip -oq "$ZIP_PATH" -d "$EXTRACT_DIR"; then
        logger warn "Failed to extract latest Hytale downloader"
        rm -rf "$TMP_DIR"
        return 1
    fi

    ARCH=$(uname -m)
    case "$ARCH" in
        aarch64|arm64)
            # ARM uses a local wrapper that launches the amd64 binary through QEMU.
            TARGET_BIN="./hytale-downloader-linux-amd64"
            TARGET_NAME="hytale-downloader-linux-amd64"
            ;;
        *)
            TARGET_BIN="$DOWNLOADER"
            TARGET_NAME=$(basename "$DOWNLOADER")
            ;;
    esac

    SOURCE_BIN="$EXTRACT_DIR/$TARGET_NAME"
    if [ ! -f "$SOURCE_BIN" ]; then
        logger warn "Latest downloader archive does not contain $TARGET_NAME"
        rm -rf "$TMP_DIR"
        return 1
    fi

    if [ -f "$TARGET_BIN" ]; then
        cp -f "$TARGET_BIN" "${TARGET_BIN}.bak" 2>/dev/null || true
    fi

    if ! cp -f "$SOURCE_BIN" "$TARGET_BIN"; then
        logger warn "Failed to replace Hytale downloader binary"
        rm -rf "$TMP_DIR"
        return 1
    fi

    chmod +x "$TARGET_BIN"

    if ! $DOWNLOADER -print-version -skip-update-check >/dev/null 2>&1; then
        logger warn "Updated downloader failed validation, restoring previous binary"
        if [ -f "${TARGET_BIN}.bak" ]; then
            cp -f "${TARGET_BIN}.bak" "$TARGET_BIN"
            chmod +x "$TARGET_BIN"
        fi
        rm -rf "$TMP_DIR"
        return 1
    fi

    rm -f "${TARGET_BIN}.bak"
    rm -rf "$TMP_DIR"

    if [ -n "$CURRENT_VERSION" ] && [ -n "$LATEST_VERSION" ]; then
        logger success "Hytale downloader updated: $CURRENT_VERSION -> $LATEST_VERSION"
    else
        logger success "Hytale downloader updated"
    fi

    return 0
}

ensure_downloader_latest() {
    local CHECK_OUTPUT
    local LATEST_VERSION
    local CURRENT_VERSION

    logger info "Checking for downloader updates..."
    CHECK_OUTPUT=$($DOWNLOADER -check-update 2>&1)

    if [ $? -ne 0 ]; then
        logger warn "Downloader update check failed, continuing with existing downloader"
        return 0
    fi

    LATEST_VERSION=$(echo "$CHECK_OUTPUT" | extract_downloader_latest_version)
    CURRENT_VERSION=$(echo "$CHECK_OUTPUT" | extract_downloader_current_version)

    if [ -z "$LATEST_VERSION" ]; then
        logger info "Downloader is up to date"
        return 0
    fi

    logger warn "New Hytale downloader available${CURRENT_VERSION:+: $CURRENT_VERSION -> $LATEST_VERSION}"

    if ! install_downloader_update "$LATEST_VERSION" "$CURRENT_VERSION"; then
        logger warn "Could not update downloader automatically, continuing with existing downloader"
    fi
}

run_update_process() {
    local INITIAL_SETUP=0

    # Check if credentials file exists, if not run the initial setup
    if [ ! -f "$DOWNLOAD_CRED_FILE" ]; then
        INITIAL_SETUP=1
        run_initial_setup
    fi

    # Check if automatic update is enabled
    if [ "$AUTOMATIC_UPDATE" = "1" ] && [ "$INITIAL_SETUP" = "0" ]; then
        run_auto_update
    fi

    # Check if patchline has changed if so update the server
    if [ -f "$PATCHLINE_CACHE_FILE" ]; then
        local CACHED_PATCHLINE=$(cat "$PATCHLINE_CACHE_FILE")

        if [ -z "$CACHED_PATCHLINE" ]; then
            logger warn "Patchline cache is empty, saving current patchline without re-downloading"
            save_patchline_version
        elif [ "$PATCHLINE" != "$CACHED_PATCHLINE" ]; then
            logger warn "Patchline mismatch, running update..."
            ensure_downloader_latest

            if ! $DOWNLOADER -patchline "$PATCHLINE" -download-path server.zip -skip-update-check; then
                logger error "Failed to download Hytale server files."
                exit 1
            fi

            save_patchline_version
            save_server_version
            extract_server_files

            logger success "Server has been successfully updated to patchline: $PATCHLINE"
        else
            logger info "Patchline match, skipping change"
        fi
    else
        logger warn "Patchline file not found, Saving patchline!"
        save_patchline_version
    fi
}

run_patchline_change() {
    logger info "Updating server to patchline: $PATCHLINE"

    ensure_downloader_latest
    if ! $DOWNLOADER -patchline "$PATCHLINE" -download-path server.zip -skip-update-check; then
        echo ""
        logger error "Failed to download Hytale server files."
        logger warn "Removing invalid credential file..."
        rm -f "$DOWNLOAD_CRED_FILE"
        exit 1
    fi

    echo "$PATCHLINE" > "$PATCHLINE_CACHE_FILE"
    logger success "Selected patchline saved!"

    save_server_version

    extract_server_files
    logger success "Server has been successfully updated to patchline: $PATCHLINE"
}

run_initial_setup() {
    logger warn "Credentials file not found, running initial setup..."
    logger info "Downloading server files..."

    ensure_downloader_latest

    echo " "
    printc "{MAGENTA}╔══════════════════════════════════════════════════════════════════════════════════════╗"
    printc "{MAGENTA}║  {BLUE}NOTE: You must have purchased Hytale on the account you are using to authenticate.  {MAGENTA}║"
    printc "{MAGENTA}╚══════════════════════════════════════════════════════════════════════════════════════╝"
    echo " "

    if ! $DOWNLOADER -patchline "$PATCHLINE" -download-path server.zip -skip-update-check; then
        echo ""
        logger error "Failed to download Hytale server files."
        logger warn "Removing invalid credential file..."
        rm -f "$DOWNLOAD_CRED_FILE"
        exit 1
    fi

    save_patchline_version
    save_server_version
    extract_server_files
}

run_auto_update() {
    # Run automatic update if enabled
    logger info "Checking for updates..."

    # Update the downloader itself first. The downloader only prints update notices;
    # it does not replace itself, so we download and install the new binary here.
    ensure_downloader_latest

    # Get the latest version for this patchline from the downloader output
    local DOWNLOAD_OUTPUT=$($DOWNLOADER -patchline "$PATCHLINE" -print-version -skip-update-check 2>&1)
    local REMOTE_VERSION=$(echo "$DOWNLOAD_OUTPUT" | extract_first_version)

    local LOCAL_VERSION=""
    if [ -f "$VERSION_FILE" ]; then
        LOCAL_VERSION=$(cat "$VERSION_FILE")
    fi

    if [ -n "$LOCAL_VERSION" ]; then
        logger info "Local version: $LOCAL_VERSION"
    fi

    if [ -n "$REMOTE_VERSION" ]; then
        logger info "Remote version: $REMOTE_VERSION"
    fi

    # If we can compare versions, skip download when they match.
    # Same build hash with a different date prefix is treated as up to date.
    if server_versions_match "$LOCAL_VERSION" "$REMOTE_VERSION"; then
        if [ "$LOCAL_VERSION" != "$REMOTE_VERSION" ]; then
            logger info "Server build hash matches; refreshing cached version without downloading server.zip"
            echo "$REMOTE_VERSION" > "$VERSION_FILE"
            save_patchline_version
        else
            logger info "Server is up to date"
        fi
        return
    fi

    # Download the update
    logger info "Downloading server files for patchline: $PATCHLINE..."
    if $DOWNLOADER -patchline "$PATCHLINE" -download-path server.zip -skip-update-check; then
        # Save the remote version if detected, otherwise fall back to -print-version
        if [ -n "$REMOTE_VERSION" ]; then
            echo "$REMOTE_VERSION" > "$VERSION_FILE"
            logger success "Saved version info!"
        else
            save_server_version
        fi
        save_patchline_version
        extract_server_files
        logger success "Server has been updated successfully!"
    else
        logger warn "Download failed, continuing with existing files"
    fi
}

save_patchline_version() {
    echo "$PATCHLINE" > "$PATCHLINE_CACHE_FILE"
    logger success "Selected patchline saved!"
}

save_server_version() {
    local SERVER_VERSION_OUTPUT
    local SERVER_VERSION

    SERVER_VERSION_OUTPUT=$($DOWNLOADER -patchline "$PATCHLINE" -print-version -skip-update-check 2>&1)
    SERVER_VERSION=$(echo "$SERVER_VERSION_OUTPUT" | extract_first_version)

    if [ -n "$SERVER_VERSION" ]; then
        echo "$SERVER_VERSION" > "$VERSION_FILE"
        logger success "Saved version info!"
    else
        logger error "Failed to get server version."
        exit 1
    fi
}

# Backwards-compatible name used by older scripts/forks.
save_downloader_version() {
    save_server_version
}

validate_server_files() {
    if [ ! -f "HytaleServer.jar" ]; then
        logger error "HytaleServer.jar not found!"
        logger error "Server files were not downloaded correctly."
        exit 1
    fi
}
