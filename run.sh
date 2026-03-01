#!/bin/bash

# Build the project
swiftc transcriber.swift -o transcriber

# Kill existing instances
pkill transcriber 2>/dev/null

# Start the new instance
nohup ./transcriber > startup.log 2>&1 &
echo "Started Transcriber. Check transcriber.log for activity."
