#!/bin/bash

# Set paths
SOURCE="/Users/floswald/JPE"
DEST="/Users/floswald/Dropbox/JPE/database"
DATE=$(date +"%Y-%m-%d_%H-%M-%S")

# Ensure destination exists
mkdir -p "$DEST"

# Copy the current database file
cp "$SOURCE/jpe.duckdb" "$DEST/backup_$DATE.duckdb"
cp "$SOURCE/arrivals.csv" "$DEST/backup_$DATE_arrivals.csv"
cp "$SOURCE/papers.csv" "$DEST/backup_$DATE_papers.csv"
# cp "$SOURCE/reports.csv" "$DEST/backup_$DATE_reports.csv"
# cp "$SOURCE/iterations.csv" "$DEST/backup_$DATE_iterations.csv"

# Keep only the 10 most recent backups, delete the rest
ls -1t "$DEST"/backup_*.duckdb | tail -n +11 | while read -r old_backup; do
  rm "$old_backup"
done
