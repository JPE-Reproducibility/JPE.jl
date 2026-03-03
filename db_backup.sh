#!/bin/bash

# Set paths
SOURCE="${JPE_DB}"
DEST="${JPE_DB_BACKUPS}"
DATE=$(date +"%Y-%m-%d_%H-%M-%S")

# Ensure destination exists
mkdir -p "$DEST"

# Copy the current database file
cp -v "$SOURCE/jpe.duckdb" "$DEST/backup_$DATE.duckdb"
cp -v "$SOURCE/arrivals.csv" "$DEST/backup_${DATE}_arrivals.csv"
cp -v "$SOURCE/papers.csv" "$DEST/backup_${DATE}_papers.csv"
cp -v "$SOURCE/reports.csv" "$DEST/backup_${DATE}_reports.csv"
cp -v "$SOURCE/iterations.csv" "$DEST/backup_${DATE}_iterations.csv"

# Keep only the 10 most recent backups, delete the rest
ls -1t "$DEST"/backup_*.duckdb | tail -n +11 | while read -r old_backup; do
  rm "$old_backup"
done
