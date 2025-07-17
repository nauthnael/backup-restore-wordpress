#!/bin/bash

# Script to backup or restore WordPress files and database on Ubuntu Linux.
# This script must be run from the WordPress installation directory.
# It reads database connection details from wp-config.php.
# Backups are stored in a 'backups' subdirectory with timestamped files.
# Database backup is compressed using gzip.
# Handles DB_HOST with port (e.g., 'localhost:3306') by separating host and port.
# Appends domain to backup filenames by querying the 'siteurl' from the wp_options table in the database.
# Prompts the user to decide whether to include the wp-content/uploads directory in the files backup.
# Performs a dry-run integrity check on the backup files after creation.
# Checks for existing backups in the 'backups' directory. If multiple matching backup pairs exist, lists them for the user to select which one to restore.
# Before restoring, performs a dry-run integrity check on the selected backup files and displays success message for user reassurance.
# During restore, prompts the user to choose whether to restore both DB and files, only DB, or only files.
# Adds color formatting to messages for better visibility: green for success, red for errors, yellow for warnings/info.
# File naming structure: backup-domain-db-timestamp.sql.gz and backup-domain-files-timestamp.tar.gz (where domain is from DOMAIN_SUFFIX without the leading hyphen in description).

# Define colors
RED='\e[1;31m'
GREEN='\e[1;32m'
YELLOW='\e[1;33m'
NC='\e[0m' # No Color

# Exit on error
set -e

# Check if wp-config.php exists
if [ ! -f "wp-config.php" ]; then
    echo -e "${RED}Error: wp-config.php not found. Ensure the script is run from the WordPress root directory.${NC}"
    exit 1
fi

# Extract database credentials from wp-config.php
DB_NAME=$(grep -oP "define\s*\(\s*'DB_NAME'\s*,\s*'\K[^']+" wp-config.php)
DB_USER=$(grep -oP "define\s*\(\s*'DB_USER'\s*,\s*'\K[^']+" wp-config.php)
DB_PASSWORD=$(grep -oP "define\s*\(\s*'DB_PASSWORD'\s*,\s*'\K[^']+" wp-config.php)
DB_HOST=$(grep -oP "define\s*\(\s*'DB_HOST'\s*,\s*'\K[^']+" wp-config.php)

# Validate extracted values
if [ -z "$DB_NAME" ] || [ -z "$DB_USER" ] || [ -z "$DB_PASSWORD" ] || [ -z "$DB_HOST" ]; then
    echo -e "${RED}Error: Could not extract all database credentials from wp-config.php.${NC}"
    exit 1
fi

# Parse DB_HOST for host and port
if [[ $DB_HOST == *:* ]]; then
    HOST=${DB_HOST%%:*}
    PORT=${DB_HOST##*:}
else
    HOST=$DB_HOST
    PORT=3306
fi

# Query the database for siteurl from wp_options
SITEURL=$(mysql -u "$DB_USER" -p"$DB_PASSWORD" -h "$HOST" -P "$PORT" -D "$DB_NAME" --skip-column-names -B -e "SELECT option_value FROM wp_options WHERE option_name = 'siteurl' LIMIT 1;" 2>/dev/null || echo "")

# Parse domain from SITEURL if available
DOMAIN=""
if [ -n "$SITEURL" ]; then
    # Remove protocol
    TEMP=${SITEURL#*://}
    # Remove path if present
    DOMAIN=${TEMP%%/*}
    # Append hyphen if domain is extracted
    if [ -n "$DOMAIN" ]; then
        DOMAIN_SUFFIX="-$DOMAIN"
    else
        DOMAIN_SUFFIX=""
    fi
else
    DOMAIN_SUFFIX=""
fi

# Escape special regex characters in DOMAIN_SUFFIX for sed pattern
DOMAIN_SUFFIX_ESC=$(printf '%s' "$DOMAIN_SUFFIX" | sed 's/[\[\]\.^$*]/\\&/g')

# Define backups directory
BACKUP_DIR="backups"

# Function to find all matching backup pairs, sorted by timestamp descending
find_all_backup_pairs() {
    # List all db backups
    DB_FILES=$(ls -1 "$BACKUP_DIR"/backup${DOMAIN_SUFFIX}-db-*.sql.gz 2>/dev/null | sort -r)
    if [ -z "$DB_FILES" ]; then
        return 1
    fi
    local PAIRS=()
    for DB_FILE in $DB_FILES; do
        TIMESTAMP=$(basename "$DB_FILE" | sed -E "s/backup${DOMAIN_SUFFIX_ESC}-db-(.*)\.sql\.gz/\1/")
        FILES_FILE="$BACKUP_DIR/backup${DOMAIN_SUFFIX}-files-${TIMESTAMP}.tar.gz"
        if [ -f "$FILES_FILE" ]; then
            PAIRS+=("$DB_FILE:$FILES_FILE")
        fi
    done
    if [ ${#PAIRS[@]} -eq 0 ]; then
        return 1
    fi
    for PAIR in "${PAIRS[@]}"; do
        echo "$PAIR"
    done
    return 0
}

# Check for existing backups and prompt for restore
if [ -d "$BACKUP_DIR" ]; then
    ALL_PAIRS=$(find_all_backup_pairs)
    if [ $? -eq 0 ]; then
        echo -e "${YELLOW}Existing backup pairs found:${NC}"
        IFS=$'\n'
        PAIR_ARRAY=($ALL_PAIRS)
        unset IFS
        for i in "${!PAIR_ARRAY[@]}"; do
            DB_FILE=$(echo "${PAIR_ARRAY[$i]}" | cut -d':' -f1)
            FILES_FILE=$(echo "${PAIR_ARRAY[$i]}" | cut -d':' -f2)
            TIMESTAMP=$(basename "$DB_FILE" | sed -E "s/backup${DOMAIN_SUFFIX_ESC}-db-(.*)\.sql\.gz/\1/")
            echo -e "${YELLOW}$((i+1)). Timestamp: $TIMESTAMP${NC}"
            echo "   Database: $DB_FILE"
            echo "   Files: $FILES_FILE"
        done
        read -p "Do you want to restore from one of these backups? Enter the number (or 0 to skip): " SELECTED
        if [ "$SELECTED" -gt 0 ] && [ "$SELECTED" -le "${#PAIR_ARRAY[@]}" ]; then
            SELECTED_PAIR="${PAIR_ARRAY[$((SELECTED-1))]}"
            LATEST_DB=$(echo "$SELECTED_PAIR" | cut -d':' -f1)
            LATEST_FILES=$(echo "$SELECTED_PAIR" | cut -d':' -f2)
            read -p "What do you want to restore? (1: Both DB and Files, 2: Only DB, 3: Only Files): " RESTORE_TYPE
            if [ "$RESTORE_TYPE" != "1" ] && [ "$RESTORE_TYPE" != "2" ] && [ "$RESTORE_TYPE" != "3" ]; then
                echo -e "${RED}Invalid selection. Restore cancelled.${NC}"
                exit 1
            fi
            read -p "Confirm restore? This will overwrite selected components! (y/n): " RESTORE_CONFIRM
            if [[ $RESTORE_CONFIRM =~ ^[Yy]$ ]]; then
                # Perform dry-run integrity checks based on selection
                echo -e "${YELLOW}Performing dry-run integrity checks on selected backup files...${NC}"

                if [ "$RESTORE_TYPE" = "1" ] || [ "$RESTORE_TYPE" = "2" ]; then
                    # Check database backup
                    gunzip -t "$LATEST_DB" > /dev/null 2>&1
                    if [ $? -eq 0 ]; then
                        echo -e "${GREEN}Database backup integrity check passed.${NC}"
                    else
                        echo -e "${RED}Error: Database backup integrity check failed.${NC}"
                        exit 1
                    fi
                fi

                if [ "$RESTORE_TYPE" = "1" ] || [ "$RESTORE_TYPE" = "3" ]; then
                    # Check files backup
                    tar -tzf "$LATEST_FILES" > /dev/null 2>&1
                    if [ $? -eq 0 ]; then
                        echo -e "${GREEN}Files backup integrity check passed.${NC}"
                    else
                        echo -e "${RED}Error: Files backup integrity check failed.${NC}"
                        exit 1
                    fi
                fi

                echo -e "${GREEN}Backup files are intact and ready for restore.${NC}"

                # Restore based on selection
                if [ "$RESTORE_TYPE" = "1" ] || [ "$RESTORE_TYPE" = "2" ]; then
                    echo -e "${YELLOW}Restoring database...${NC}"
                    gunzip < "$LATEST_DB" | mysql -u "$DB_USER" -p"$DB_PASSWORD" -h "$HOST" -P "$PORT" "$DB_NAME"
                    if [ $? -eq 0 ]; then
                        echo -e "${GREEN}Database restored successfully.${NC}"
                    else
                        echo -e "${RED}Error: Database restore failed.${NC}"
                        exit 1
                    fi
                fi

                if [ "$RESTORE_TYPE" = "1" ] || [ "$RESTORE_TYPE" = "3" ]; then
                    echo -e "${YELLOW}Restoring files...${NC}"
                    tar -xzf "$LATEST_FILES" -C .
                    if [ $? -eq 0 ]; then
                        echo -e "${GREEN}Files restored successfully.${NC}"
                    else
                        echo -e "${RED}Error: Files restore failed.${NC}"
                        exit 1
                    fi
                fi

                echo -e "${GREEN}Restore process completed successfully.${NC}"
                exit 0
            else
                echo -e "${YELLOW}Restore cancelled. Proceeding with backup.${NC}"
            fi
        else
            echo -e "${YELLOW}No restore selected. Proceeding with backup.${NC}"
        fi
    fi
fi

# Prompt user for backing up uploads directory
read -p "Do you want to include the wp-content/uploads directory in the files backup? (y/n): " INCLUDE_UPLOADS
if [[ $INCLUDE_UPLOADS =~ ^[Yy]$ ]]; then
    EXCLUDE_UPLOADS=""
    echo -e "${YELLOW}Including wp-content/uploads in the backup.${NC}"
else
    EXCLUDE_UPLOADS="--exclude=wp-content/uploads"
    echo -e "${YELLOW}Excluding wp-content/uploads from the backup.${NC}"
fi

# Create backups directory if it doesn't exist
mkdir -p "$BACKUP_DIR"

# Generate timestamp for backup files
TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")

# Backup database using mysqldump and compress with gzip
DB_BACKUP_FILE="$BACKUP_DIR/backup${DOMAIN_SUFFIX}-db-$TIMESTAMP.sql.gz"
mysqldump -u "$DB_USER" -p"$DB_PASSWORD" -h "$HOST" -P "$PORT" "$DB_NAME" | gzip > "$DB_BACKUP_FILE"
if [ $? -eq 0 ]; then
    echo -e "${GREEN}Compressed database backup created: $DB_BACKUP_FILE${NC}"
else
    echo -e "${RED}Error: Database backup failed.${NC}"
    exit 1
fi

# Backup files (exclude the backups directory to avoid recursion, and optionally exclude uploads)
FILES_BACKUP_FILE="$BACKUP_DIR/backup${DOMAIN_SUFFIX}-files-$TIMESTAMP.tar.gz"
tar -czf "$FILES_BACKUP_FILE" --exclude="$BACKUP_DIR" $EXCLUDE_UPLOADS .
if [ $? -eq 0 ]; then
    echo -e "${GREEN}Files backup created: $FILES_BACKUP_FILE${NC}"
else
    echo -e "${RED}Error: Files backup failed.${NC}"
    exit 1
fi

# Perform dry-run integrity checks
echo -e "${YELLOW}Performing dry-run integrity checks on backup files...${NC}"

# Check database backup (test gzip integrity)
gunzip -t "$DB_BACKUP_FILE" > /dev/null 2>&1
if [ $? -eq 0 ]; then
    echo -e "${GREEN}Database backup integrity check passed.${NC}"
else
    echo -e "${RED}Error: Database backup integrity check failed.${NC}"
    exit 1
fi

# Check files backup (list contents without extracting)
tar -tzf "$FILES_BACKUP_FILE" > /dev/null 2>&1
if [ $? -eq 0 ]; then
    echo -e "${GREEN}Files backup integrity check passed.${NC}"
else
    echo -e "${RED}Error: Files backup integrity check failed.${NC}"
    exit 1
fi

echo -e "${GREEN}Backup process and integrity checks completed successfully.${NC}"
