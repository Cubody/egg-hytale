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
        local CACHED_PATCHLINE=$(cat $PATCHLINE_CACHE_FILE)

        if [ "$PATCHLINE" != "$CACHED_PATCHLINE" ]; then
            logger warn "Patchline mismatch, running update..."
            $DOWNLOADER -check-update
            $DOWNLOADER -patchline $PATCHLINE -download-path server.zip

            save_patchline_version
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

    $DOWNLOADER -check-update
    if ! $DOWNLOADER -patchline $PATCHLINE -download-path server.zip; then
        echo ""
        logger error "Failed to download Hytale server files."
        logger warn "Removing invalid credential file..."
        rm -f $DOWNLOAD_CRED_FILE
        exit 1
    fi

    echo "$PATCHLINE" > "$PATCHLINE_CACHE_FILE"
    logger success "Selected patchline saved!"

    save_downloader_version

    extract_server_files
    logger success "Server has been successfully updated to patchline: $PATCHLINE"
}

run_initial_setup() {
    logger warn "Credentials file not found, running initial setup..."
    logger info "Downloading server files..."

    $DOWNLOADER -check-update

    echo " "
    printc "{MAGENTA}╔══════════════════════════════════════════════════════════════════════════════════════╗"
    printc "{MAGENTA}║  {BLUE}NOTE: You must have purchased Hytale on the account you are using to authenticate.  {MAGENTA}║"
    printc "{MAGENTA}╚══════════════════════════════════════════════════════════════════════════════════════╝"
    echo " "

    if ! $DOWNLOADER -patchline $PATCHLINE -download-path server.zip; then
        echo ""
        logger error "Failed to download Hytale server files."
        logger warn "Removing invalid credential file..."
        rm -f $DOWNLOAD_CRED_FILE
        exit 1
    fi

    save_patchline_version
    save_downloader_version
    extract_server_files
}

run_auto_update() {
    # Run automatic update if enabled
    logger info "Checking for updates..."

    # Update the downloader itself first
    $DOWNLOADER -check-update

    # Always run the downloader - it handles version checking internally
    # and only downloads if a newer version is available for the patchline
    logger info "Downloading latest server files for patchline: $PATCHLINE..."
    if $DOWNLOADER -patchline $PATCHLINE -download-path server.zip; then
        save_patchline_version
        save_downloader_version
        extract_server_files
        logger success "Server has been updated successfully!"
    else
        logger warn "Download failed or no update available, continuing with existing files"
    fi
}

save_patchline_version() {
    echo "$PATCHLINE" > $PATCHLINE_CACHE_FILE
    logger success "Selected patchline saved!"
}

save_downloader_version() {
    local DOWNLOADER_VERSION=$($DOWNLOADER -print-version -skip-update-check 2>&1)
    if [ $? -eq 0 ] && [ -n "$DOWNLOADER_VERSION" ]; then
        echo "$DOWNLOADER_VERSION" > $VERSION_FILE
        logger success "Saved version info!"
    else
        logger error "Failed to get downloader version."
        exit 1
    fi
}

validate_server_files() {
    if [ ! -f "HytaleServer.jar" ]; then
        logger error "HytaleServer.jar not found!"
        logger error "Server files were not downloaded correctly."
        exit 1
    fi
}