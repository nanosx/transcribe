#!/bin/bash

PROJECT_DIR="path_to_the_project_directory"
LOG_FILE="$PROJECT_DIR/startup.log"

# Navigate to the project directory
cd "$PROJECT_DIR" || exit 1

pkill -f "transcriber"

# Start the transcriber
./transcriber >> "$LOG_FILE" 2>&1
